import Foundation

struct Release: Codable { let id: String, name: String, version: String, build: String, url: String; let size: Int64 }
func versionComponents(_ text: String) -> [Int] { text.split(separator: ".").compactMap { Int($0) } }
func moreRecent(_ a: String, _ b: String) -> Bool {
    let x = versionComponents(a), y = versionComponents(b)
    for n in 0..<max(x.count, y.count) { let l = n < x.count ? x[n] : 0, r = n < y.count ? y[n] : 0; if l != r { return l > r } }; return false
}
func fiveGenerations(_ entries: [Release]) -> [Release] {
    var seen = Set<Int>()
    return Array(entries.sorted { moreRecent($0.version, $1.version) }.filter { seen.insert(versionComponents($0.version).first ?? 0).inserted }.prefix(5))
}
func officialURL(_ text: String) -> Bool {
    guard let u = URL(string: text), u.scheme == "https", u.user == nil, u.password == nil, let host = u.host?.lowercased() else { return false }
    return ["swscan.apple.com", "swdist.apple.com", "swcdn.apple.com"].contains(host)
}
func transferArguments(_ url: String, _ path: String, resume: Bool) -> [String] {
    var args = ["--disable", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--noproxy", "*", "--connect-timeout", "20", "--silent", "--show-error"]
    args += resume ? ["--continue-at", "-", "--speed-time", "60", "--speed-limit", "1024"] : ["--max-time", "90"]
    return args + ["--output", path, url]
}
func fetchOfficial(_ url: String, to path: String) throws {
    guard officialURL(url) else { throw problem("Источник не является HTTPS-сервером Apple") }
    try execute("/usr/bin/curl", transferArguments(url, path, resume: false))
}
func readCatalog(_ directory: URL) throws -> [Release] {
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = directory.appendingPathComponent("catalog.gz").path
    let url = "https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"
    // The public production catalog also lists newer generations as Apple publishes them.
    try fetchOfficial(url, to: archive)
    let data = try execute("/usr/bin/gunzip", ["-c", archive]).data
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let products = plist["Products"] as? [String: [String: Any]] else { throw problem("Неизвестный формат каталога Apple") }
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 4; let lock = NSLock(); var result = [Release](), failures = [String]()
    for (id, product) in products {
        guard id.range(of: "^[0-9-]+$", options: .regularExpression) != nil, let packages = product["Packages"] as? [[String: Any]], let pkg = packages.first(where: { ($0["URL"] as? String)?.hasSuffix("/InstallAssistant.pkg") == true }), let url = pkg["URL"] as? String, officialURL(url), let size = pkg["Size"] as? NSNumber, let distributions = product["Distributions"] as? [String: String], let dist = distributions["English"] ?? distributions.values.first, officialURL(dist) else { continue }
        queue.addOperation {
            do {
                let path = directory.appendingPathComponent(id + ".dist").path; try fetchOfficial(dist, to: path)
                let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [])
                guard let aux = try xml.nodes(forXPath: "/installer-gui-script/auxinfo/dict").first?.xmlString else { throw problem("Нет версии в каталоге") }
                let meta = try PropertyListSerialization.propertyList(from: Data(("<?xml version=\"1.0\"?><plist version=\"1.0\">" + aux + "</plist>").utf8), format: nil) as? [String: String]
                guard let version = meta?["VERSION"], !versionComponents(version).isEmpty else { throw problem("Неизвестная версия macOS") }
                let name = try xml.nodes(forXPath: "/installer-gui-script/title").first?.stringValue ?? "macOS"
                let value = Release(id: id, name: name, version: version, build: meta?["BUILD"] ?? "", url: url, size: size.int64Value)
                lock.lock(); result.append(value); lock.unlock()
            } catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    guard failures.isEmpty, !result.isEmpty else { throw problem("Каталог загружен не полностью. " + (failures.first ?? "Установщики не найдены")) }
    return fiveGenerations(result)
}
