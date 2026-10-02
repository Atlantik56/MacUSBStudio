import Foundation
import Darwin

func record(_ inputDirectory: String) throws -> RecordingResult {
    guard getuid() == 0 else { throw problem("Для записи нужны права администратора") }
    let directory = try checkedJobDirectory(inputDirectory)
    try ensureNoOtherRecorder()
    let lock = directory + "/write.lock"; try files.createDirectory(atPath: lock, withIntermediateDirectories: false); defer { try? files.removeItem(atPath: lock) }
    try String(getpid()).write(toFile: directory + "/worker.pid", atomically: true, encoding: .utf8)
    let job = try readJSON(RecordingJob.self, directory + "/job.json")
    guard ["app", "pkg"].contains(job.kind), try checkedJobDirectory(URL(fileURLWithPath: job.source).deletingLastPathComponent().path) == directory, !job.source.contains("..") else { throw problem("Источник не подготовлен для записи") }
    say("STAGE: Проверка установщика Apple")
    if job.kind == "pkg" {
        guard fileBytes(job.source) == job.sourceBytes, try checkPackage(job.source) == job.installedApp else { throw problem("Подготовленный пакет изменился") }
        say("STAGE: Извлечение приложения установщика — сама macOS не устанавливается")
        try execute("/usr/sbin/installer", ["-pkg", job.source, "-target", "/"], stream: true)
    } else { guard job.installedApp == job.source else { throw problem("Неверный путь установщика") } }
    try checkInstaller(job.installedApp)
    say("STAGE: Проверка выбранного USB")
    try validate(job.usb)
    guard job.usb.size >= 24_000_000_000 else { throw problem("Нужен USB от 24 ГБ, рекомендуется 32 ГБ или больше") }
    say("TARGET: " + job.usb.label)
    say("STAGE: Форматирование выбранной флешки — GUID / HFS+")
    try validate(job.usb)
    try execute("/usr/sbin/diskutil", ["eraseDisk", "JHFS+", "MacUSBInstaller", "GPT", "/dev/" + job.usb.id], stream: true)
    let (mount, _) = try mountedVolume(job.usb); try validate(job.usb)
    say("STAGE: Запись официальным установщиком Apple")
    let result = try execute(job.installedApp + "/Contents/Resources/createinstallmedia", ["--volume", mount, "--nointeraction"], stream: true)
    say("STAGE: Проверка готового носителя")
    try validate(job.usb)
    let (finalMount, info) = try mountedVolume(job.usb), whole = try diskInfo(job.usb.id)
    let installed = finalMount + "/" + URL(fileURLWithPath: job.installedApp).lastPathComponent
    let support = installed + "/Contents/SharedSupport"
    let payload = (try? files.contentsOfDirectory(atPath: support))?.contains(where: { fileBytes(support + "/" + $0) > 1_000_000_000 }) == true
    guard outputIsReady(commandCode: result.code, guid: whole["Content"] as? String == "GUID_partition_scheme", hfs: info["FilesystemType"] as? String == "hfs", bootable: info["Bootable"] as? Bool == true, physicalMedia: files.fileExists(atPath: finalMount + "/.IAPhysicalMedia"), installerPayload: payload) else { throw problem("Apple завершил запись, но проверка структуры носителя не пройдена. Журнал сохранён; повторное стирание не запускается.") }
    return RecordingResult(success: true, message: "Флешка создана. Apple завершил запись; структура носителя проверена.", mount: finalMount)
}

// Development test of the real elevation/privacy path. It cannot format or run an installer.
func testConsoleAccess(_ inputDirectory: String) throws -> RecordingResult {
    guard getuid() == 0 else { throw problem("Для теста нужны права администратора") }
    let directory = try checkedJobDirectory(inputDirectory)
    try ensureNoOtherRecorder()
    let job = try readJSON(RecordingJob.self, directory + "/job.json")
    guard job.kind == "console-test", job.source.isEmpty, job.installedApp.isEmpty else { throw problem("Неверное тестовое задание") }
    let lock = directory + "/write.lock"; try files.createDirectory(atPath: lock, withIntermediateDirectories: false); defer { try? files.removeItem(atPath: lock) }
    try String(getpid()).write(toFile: directory + "/worker.pid", atomically: true, encoding: .utf8)
    say("STAGE: Проверка прав администратора — получены")
    try validate(job.usb)
    let (mount, _) = try mountedVolume(job.usb)
    let probe = URL(fileURLWithPath: mount).appendingPathComponent(".mac-usb-console-test-" + UUID().uuidString)
    let data = Data("Mac USB Studio console access test\n".utf8)
    say("STAGE: Проверка доступа к USB — временный файл, без форматирования")
    try data.write(to: probe, options: .withoutOverwriting)
    do {
        guard try Data(contentsOf: probe) == data else { throw problem("Тестовый файл прочитан неверно") }
        try files.removeItem(at: probe)
    } catch { try? files.removeItem(at: probe); throw error }
    return RecordingResult(success: true, message: "Встроенная консоль проверена: права администратора и запись на USB доступны. Тестовый файл удалён; флешка не форматировалась.", mount: mount)
}

@main struct Recorder {
    static func main() {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--self-check" { print("MAC_USB_RECORDER_2_OK"); return }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-job" {
            do {
                let directory = try checkedJobDirectory(CommandLine.arguments[2])
                let job = try readJSON(RecordingJob.self, directory + "/job.json")
                guard try checkedJobDirectory(URL(fileURLWithPath: job.source).deletingLastPathComponent().path) == directory else { throw problem("Источник находится вне задания") }
                if job.kind == "app" { try checkInstaller(job.source) } else { guard try checkPackage(job.source) == job.installedApp else { throw problem("Пакет изменился") } }
                try validate(job.usb); print("JOB_CHECK_OK: " + directory); return
            } catch { print(error.localizedDescription); exit(1) }
        }
        guard CommandLine.arguments.count == 3, ["--write", "--console-test"].contains(CommandLine.arguments[1]) else { fputs("Unsupported command\n", stderr); exit(2) }
        let directory: String
        do { directory = try checkedJobDirectory(CommandLine.arguments[2]) }
        catch { say("FAILED: " + error.localizedDescription); exit(2) }
        let result: RecordingResult
        do { result = try CommandLine.arguments[1] == "--console-test" ? testConsoleAccess(directory) : record(directory) }
        catch { result = RecordingResult(success: false, message: error.localizedDescription, mount: nil) }
        do { try save(result, directory + "/result.json"); try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory + "/result.json") }
        catch { say("RESULT_SAVE_FAILED: " + error.localizedDescription) }
        say((result.success ? "COMPLETE: " : "FAILED: ") + result.message)
        exit(result.success ? 0 : 1)
    }
}
