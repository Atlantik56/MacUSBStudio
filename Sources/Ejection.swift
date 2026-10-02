import Foundation

func ejectionArguments(_ usb: USB, result: RecordingResult?, snapshot: RecordingSnapshot, currentDisk: [String: Any]) throws -> [String] {
    guard result?.success == true else { throw problem("Безопасное извлечение доступно после успешной записи.") }
    guard snapshot.worker == .exited, !snapshot.writerRunning, !snapshot.pidReadFailed else { throw problem("Процесс записи ещё работает или его завершение не подтверждено. Дождитесь завершения.") }
    guard usb.matches(currentDisk) else { throw problem("Записанная флешка отключена или диск изменился. Другой накопитель не извлекается.") }
    return ["eject", "/dev/" + usb.id]
}
func checkedEjectionArguments(_ directory: String) throws -> (USB, [String]) {
    let path = try checkedJobDirectory(directory)
    let job = try readJSON(RecordingJob.self, path + "/job.json")
    let snapshot = RecordingSnapshot(path)
    let args = try ejectionArguments(job.usb, result: snapshot.result, snapshot: snapshot, currentDisk: diskInfo(job.usb.id))
    try ensureNoOtherRecorder()
    try validate(job.usb)
    return (job.usb, args)
}
func ejectWrittenUSB(_ directory: String) throws -> USB {
    let (usb, args) = try checkedEjectionArguments(directory)
    // diskutil performs normal unmount and eject; never force a busy volume.
    try execute("/usr/sbin/diskutil", args)
    return usb
}
