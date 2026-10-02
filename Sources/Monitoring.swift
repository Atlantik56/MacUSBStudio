import Foundation
import Darwin

enum ProcessState: String, Codable { case running, exited, unknown }
struct ProcessSnapshot {
    let commands: [Int32: String]?
    static func capture() -> ProcessSnapshot {
        // ps escapes Cyrillic command names in the C locale, hiding a live launcher.
        guard let output = try? execute("/bin/ps", ["-axww", "-o", "pid=,command="], checked: false, locale: "en_US.UTF-8"), output.code == 0 else { return ProcessSnapshot(commands: nil) }
        var commands = [Int32: String]()
        for row in output.text.split(separator: "\n") {
            let parts = row.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if parts.count == 2, let pid = Int32(parts[0]) { commands[pid] = String(parts[1]) }
        }
        return ProcessSnapshot(commands: commands)
    }
    func state(_ pid: Int32?, matching path: String) -> ProcessState {
        guard let commands = commands else { return .unknown }
        guard let pid = pid, pid > 0, let command = commands[pid] else { return .exited }
        return commandMatches(command, path) ? .running : .exited
    }
    func writerRunning(in directory: String) -> Bool {
        let path = normalizedTemporaryPath(directory) + "/"
        return commands?.values.contains { command in
            let c = normalizedTemporaryPath(command)
            let recorder = c.contains(path + "MacUSBRecorder") && (c.hasPrefix(path) || c.hasPrefix("/usr/bin/sudo ") || c.hasPrefix("/usr/bin/caffeinate "))
            let apple = c.hasPrefix(path) && c.contains("/Contents/Resources/createinstallmedia")
            return recorder || apple
        } ?? false
    }
}
struct RecordingSnapshot {
    let log: String?, logError: String?, result: RecordingResult?, exitCode: String?
    let workerPID: Int32?, worker: ProcessState, launcher: ProcessState, writerRunning: Bool
    let pidReadFailed: Bool
    init(_ directory: String, processes: ProcessSnapshot = .capture()) {
        var text: String?, errorText: String?
        let logPath = directory + "/write.log"
        if files.fileExists(atPath: logPath) {
            do { text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: logPath)), as: UTF8.self) }
            catch { errorText = error.localizedDescription }
        } else { text = "" }
        log = text; logError = errorText
        result = try? readJSON(RecordingResult.self, directory + "/result.json")
        exitCode = (try? String(contentsOfFile: directory + "/exit-code", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        func pid(_ name: String) -> (Int32?, Bool) {
            let path = directory + "/" + name
            guard files.fileExists(atPath: path) else { return (nil, false) }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8), let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return (nil, true) }
            return (value, false)
        }
        let w = pid("worker.pid"), l = pid("launcher.pid")
        workerPID = w.0; pidReadFailed = w.1 || l.1
        worker = processes.state(w.0, matching: directory + "/MacUSBRecorder")
        launcher = processes.state(l.0, matching: recordingLauncherPath(directory))
        writerRunning = processes.writerRunning(in: directory)
    }
    // An unreadable PID/log/process list is not evidence that recording stopped.
    func confirmedStopped(elapsed: TimeInterval) -> Bool {
        guard !pidReadFailed, logError == nil, worker != .unknown, launcher != .unknown, !writerRunning, worker != .running else { return false }
        return workerPID != nil || (launcher == .exited && elapsed > 20)
    }
}
func recoverRecordingJob(_ root: String = "/private/tmp", processes: ProcessSnapshot = .capture()) -> String? {
    guard let names = try? files.contentsOfDirectory(atPath: root) else { return nil }
    var candidates = [String]()
    for name in names where name.hasPrefix("mac-usb-studio2-") {
        guard let path = try? checkedJobDirectory(root + "/" + name),
              let attributes = try? files.attributesOfItem(atPath: path + "/job.json"),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (try? readJSON(RecordingJob.self, path + "/job.json")) != nil else { continue }
        let snapshot = RecordingSnapshot(path, processes: processes)
        if snapshot.result == nil && (snapshot.writerRunning || snapshot.worker == .running || snapshot.launcher == .running) { candidates.append(path) }
    }
    return candidates.count == 1 ? candidates[0] : nil
}
