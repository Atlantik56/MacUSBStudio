import Foundation

struct USB: Codable, Equatable {
    let id: String, model: String, registry: String, tree: String
    let size: Int64
    var label: String { "\(registry) · \(readableBytes(size)) · /dev/\(id)" }
    func matches(_ p: [String: Any]) -> Bool {
        eligible(p) && p["DeviceIdentifier"] as? String == id && p["MediaName"] as? String == model && p["IORegistryEntryName"] as? String == registry && p["DeviceTreePath"] as? String == tree && (p["Size"] as? NSNumber)?.int64Value == size
    }
}
func eligible(_ p: [String: Any]) -> Bool { p["Internal"] as? Bool == false && p["OSInternalMedia"] as? Bool != true && p["WholeDisk"] as? Bool == true && p["VirtualOrPhysical"] as? String == "Physical" && p["BusProtocol"] as? String == "USB" && p["Writable"] as? Bool == true }
func connectedUSBs() throws -> [USB] {
    let p = try diskPlist(["list", "-plist", "external", "physical"])
    return try (p["AllDisksAndPartitions"] as? [[String: Any]] ?? []).compactMap { entry in
        guard let id = entry["DeviceIdentifier"] as? String else { return nil }; let i = try diskInfo(id)
        guard eligible(i), let name = i["MediaName"] as? String, let registry = i["IORegistryEntryName"] as? String, let tree = i["DeviceTreePath"] as? String, let size = i["Size"] as? NSNumber else { return nil }
        return USB(id: id, model: name, registry: registry, tree: tree, size: size.int64Value)
    }
}
func validate(_ usb: USB) throws {
    guard usb.matches(try diskInfo(usb.id)) else { throw problem("USB отключён или изменился. Выберите его заново.") }
    let same = try connectedUSBs().filter { $0.model == usb.model && $0.registry == usb.registry && $0.size == usb.size }
    guard same.count == 1 else { throw problem("Подключены одинаковые USB. Оставьте только выбранный накопитель.") }
}
func mountedVolume(_ usb: USB) throws -> (String, [String: Any]) {
    let p = try diskPlist(["list", "-plist", usb.id]); var found = [(String, [String: Any])]()
    for disk in p["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
        for part in disk["Partitions"] as? [[String: Any]] ?? [] {
            guard part["Content"] as? String == "Apple_HFS", let id = part["DeviceIdentifier"] as? String else { continue }
            let i = try diskInfo(id)
            if i["ParentWholeDisk"] as? String == usb.id, let m = i["MountPoint"] as? String, m.hasPrefix("/Volumes/") { found.append((m, i)) }
        }
    }
    guard found.count == 1 else { throw problem("Не найден единственный HFS+ том на выбранном USB") }; return found[0]
}
struct Source { let url: URL; let kind: String; let installedApp: String; let imageMount: String? }
struct RecordingJob: Codable { let usb: USB; let source: String; let kind: String; let installedApp: String; let sourceBytes: Int64 }
struct RecordingResult: Codable { let success: Bool; let message: String; let mount: String? }
struct SavedDownload: Codable { let release: Release; let path: String }
struct ProgressState: Equatable { let title: String; let percent: Double? }
func recordingProgress(_ log: String) -> ProgressState {
    let lines = log.components(separatedBy: .newlines).filter { !$0.isEmpty }
    if let phase = lines.lastIndex(where: { $0.hasPrefix("STAGE:") }) {
        let body = Array(lines[phase...])
        for line in body.reversed() {
            if line.hasPrefix("Install media now available") { return ProgressState(title: "Apple завершил запись. Проверяю результат…", percent: nil) }
            if line.contains("Making disk bootable") { return ProgressState(title: "Подготовка загрузки флешки…", percent: nil) }
            if line.contains("Copying the macOS RecoveryOS") { return ProgressState(title: "Копирование системы восстановления…", percent: nil) }
            if line.contains("Copying essential files") { return ProgressState(title: "Копирование служебных файлов…", percent: nil) }
            if line.contains("Copying to disk:") || line.contains("Erasing disk:"), let regex = try? NSRegularExpression(pattern: "([0-9]+)%"), let m = regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).last, let r = Range(m.range(at: 1), in: line), let value = Double(line[r]) {
                return ProgressState(title: line.contains("Copying to disk") ? "Копирование установщика — \(Int(value))%" : "Стирание флешки — \(Int(value))%", percent: min(100, value))
            }
        }
        return ProgressState(title: String(lines[phase].dropFirst(6)).trimmingCharacters(in: .whitespaces), percent: nil)
    }
    return ProgressState(title: "Запускаю процесс записи…", percent: nil)
}
func outputIsReady(commandCode: Int32, guid: Bool, hfs: Bool, bootable: Bool, physicalMedia: Bool, installerPayload: Bool) -> Bool { commandCode == 0 && guid && hfs && bootable && physicalMedia && installerPayload }

func launcher(_ directory: String, _ usbLabel: String) -> String {
    """
    #!/bin/bash
    cd \(quote(directory)) || exit 1
    mkdir terminal.lock 2>/dev/null || exit 1
    trap 'rmdir terminal.lock 2>/dev/null' EXIT
    printf '%s\\n' "$$" > launcher.pid
    exec > >(/usr/bin/tee -a write.log) 2>&1
    printf '%s\\n' 'STAGE: Ожидаю пароль администратора в Terminal' \(quote(usbLabel))
    printf '%s\\n' 'Введите пароль администратора. Символы пароля не отображаются.' 'При запросе macOS разрешите Terminal доступ к съёмным томам.'
    /usr/bin/sudo /usr/bin/caffeinate -dims \(quote(directory + "/MacUSBRecorder")) --write \(quote(directory))
    studio_exit=$?
    printf '%s\\n' "$studio_exit" > exit-code
    if [ "$studio_exit" -ne 0 ]; then printf '%s\\n' "Команда завершилась с кодом $studio_exit. Подробности показаны в Mac USB Studio."; fi
    printf '%s\\n' 'Операция завершена. Нажмите Enter, чтобы закрыть это окно.'
    read -r
    exit "$studio_exit"
    """
}
