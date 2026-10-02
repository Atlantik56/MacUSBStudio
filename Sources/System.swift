import Foundation
import Darwin

let files = FileManager.default
struct StudioError: LocalizedError { let message: String; var errorDescription: String? { message } }
func problem(_ message: String) -> StudioError { StudioError(message: message) }
struct Output { let code: Int32; let data: Data; var text: String { String(decoding: data, as: UTF8.self) } }
@discardableResult func execute(_ path: String, _ args: [String], stream: Bool = false, checked: Bool = true, locale: String = "C") throws -> Output {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    var env = ProcessInfo.processInfo.environment; env["LC_ALL"] = locale; p.environment = env
    p.standardOutput = stream ? FileHandle.standardOutput : pipe.fileHandleForWriting
    p.standardError = p.standardOutput
    try p.run()
    var data = Data()
    if !stream { try pipe.fileHandleForWriting.close(); data = pipe.fileHandleForReading.readDataToEndOfFile() }
    p.waitUntilExit(); let result = Output(code: p.terminationStatus, data: data)
    if checked, result.code != 0 { throw problem("\(URL(fileURLWithPath: path).lastPathComponent): код \(result.code). \(result.text.suffix(1400))") }
    return result
}
func diskPlist(_ args: [String]) throws -> [String: Any] {
    guard let p = try PropertyListSerialization.propertyList(from: execute("/usr/sbin/diskutil", args).data, format: nil) as? [String: Any] else { throw problem("Не удалось прочитать сведения диска") }; return p
}
func diskInfo(_ disk: String) throws -> [String: Any] { try diskPlist(["info", "-plist", disk]) }
func readJSON<T: Decodable>(_ type: T.Type, _ path: String) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path))) }
func save<T: Encodable>(_ value: T, _ path: String) throws { try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: path), options: .atomic) }
func fileBytes(_ path: String) -> Int64 { (try? files.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0 }
func checkedJobDirectory(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path), name = URL(fileURLWithPath: path).lastPathComponent
    let prefix = "mac-usb-studio2-"
    guard !path.contains(".."), ["/private/tmp", "/tmp"].contains(url.deletingLastPathComponent().path), name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { throw problem("Неверный каталог задания") }
    let attributes = try files.attributesOfItem(atPath: path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory, let resolved = realpath(path, nil) else { throw problem("Каталог задания отсутствует или является ссылкой") }
    defer { free(resolved) }
    let canonical = String(cString: resolved)
    guard canonical == "/private/tmp/" + name else { throw problem("Каталог задания находится вне временной папки") }
    return canonical
}
func readableBytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .decimal) }
func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func say(_ text: String) { print(text); fflush(stdout) }
func signature(_ path: String, apple: Bool = false) throws {
    var args = ["--verify", "--strict"]; if apple { args.append("-R=anchor apple") }; args.append(path)
    try execute("/usr/bin/codesign", args)
}
func treeSize(_ url: URL) throws -> Int64 {
    if !url.hasDirectoryPath && url.pathExtension != "app" { return fileBytes(url.path) }
    guard let e = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { throw problem("Не удалось прочитать размер установщика") }
    var total: Int64 = 0
    for case let u as URL in e { let v = try u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]); if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) } }; return total
}
func checkInstaller(_ path: String) throws {
    let tool = path + "/Contents/Resources/createinstallmedia"
    guard files.isExecutableFile(atPath: tool), files.fileExists(atPath: path + "/Contents/Info.plist") else { throw problem("Выберите полное приложение Install macOS … .app с createinstallmedia") }
    let dir = path + "/Contents/SharedSupport"
    guard let names = try? files.contentsOfDirectory(atPath: dir), names.contains(where: { fileBytes(dir + "/" + $0) > 1_000_000_000 }) else { throw problem("В установщике отсутствуют полные данные macOS. Скачайте полный установщик.") }
    try signature(tool, apple: true)
}
func checkPackage(_ path: String) throws -> String {
    let text = try execute("/usr/sbin/pkgutil", ["--check-signature", path]).text
    guard text.contains("signed Apple Software") else { throw problem("Пакет не подписан Apple Software") }
    let payload = try execute("/usr/sbin/pkgutil", ["--payload-files", path]).text.components(separatedBy: .newlines)
    var names = Set<String>()
    for line in payload {
        let p = line.hasPrefix("./") ? String(line.dropFirst(2)) : line
        if p.hasPrefix("Applications/Install "), let r = p.range(of: ".app"), !p.contains("..") { names.insert("/" + String(p[..<r.upperBound])) }
    }
    guard names.count == 1, let app = names.first, payload.contains(where: { $0.hasSuffix(".app/Contents/Resources/createinstallmedia") }) else { throw problem("Нужен полный пакет InstallAssistant.pkg от Apple") }; return app
}
// Terminal and Foundation can name the same temporary directory differently.
func normalizedTemporaryPath(_ text: String) -> String { text.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") }
func commandMatches(_ command: String, _ path: String) -> Bool { normalizedTemporaryPath(command).contains(normalizedTemporaryPath(path)) }
func ensureNoOtherRecorder() throws {
    let rows = try execute("/bin/ps", ["-axo", "pid=,comm="]).text.split(separator: "\n")
    for row in rows {
        let parts = row.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, let pid = Int32(parts[0]), pid != getpid() else { continue }
        let name = URL(fileURLWithPath: String(parts[1])).lastPathComponent
        if ["createinstallmedia", "MacUSBRecorder", "MacUSBWorker"].contains(name) { throw problem("Уже запущена другая запись USB. Дождитесь её завершения.") }
    }
}
