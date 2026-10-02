import Foundation

let passwordPromptMarker = "__MAC_USB_STUDIO_PASSWORD__"
func passwordPromptCount(_ log: String) -> Int { log.components(separatedBy: passwordPromptMarker).count - 1 }
func consoleText(_ log: String) -> String { log.replacingOccurrences(of: passwordPromptMarker, with: "Введите пароль администратора в поле ниже.\n") }
func embeddedLauncherPath(_ directory: String) -> String { directory + "/record-in-app.sh" }
func recordingLauncherPath(_ directory: String) -> String {
    (try? readJSON(String.self, directory + "/launch-mode.json")) == "embedded" ? embeddedLauncherPath(directory) : directory + "/Записать macOS.command"
}
func embeddedLauncher(_ directory: String, _ usbLabel: String, test: Bool = false) -> String {
    """
    #!/bin/bash
    cd \(quote(directory)) || exit 1
    mkdir terminal.lock 2>/dev/null || exit 1
    trap 'rmdir terminal.lock 2>/dev/null' EXIT
    printf '%s\\n' "$$" > launcher.pid
    printf '%s\\n' 'STAGE: Ожидаю пароль администратора в приложении' \(quote(usbLabel))
    printf '%s\\n' 'Введите пароль в защищённом поле Mac USB Studio.' 'Если macOS запросит доступ к съёмному тому, разрешите его в системном окне.'
    /usr/bin/sudo -S -p \(quote(passwordPromptMarker)) /usr/bin/caffeinate -dims \(quote(directory + "/MacUSBRecorder")) \(test ? "--console-test" : "--write") \(quote(directory))
    studio_exit=$?
    printf '%s\\n' "$studio_exit" > exit-code
    if [ "$studio_exit" -ne 0 ]; then printf '%s\\n' "Команда завершилась с кодом $studio_exit. Подробности показаны выше."; fi
    printf '%s\\n' 'Операция завершена.'
    exit "$studio_exit"
    """
}
final class ConsoleSession {
    let process = Process()
    let input = Pipe()
    private var output: FileHandle?
    var submittedPrompts = 0
    func start(_ directory: String) throws {
        let path = try checkedJobDirectory(directory)
        let log = path + "/write.log"
        if !files.fileExists(atPath: log) { try Data().write(to: URL(fileURLWithPath: log), options: .withoutOverwriting) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log)); try handle.seekToEnd(); output = handle
        process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [embeddedLauncherPath(path)]; process.currentDirectoryURL = URL(fileURLWithPath: path)
        var env = ProcessInfo.processInfo.environment; env["LC_ALL"] = "en_US.UTF-8"; env["TERM"] = "dumb"; process.environment = env
        process.standardInput = input.fileHandleForReading
        // Children write directly to the file; closing the GUI cannot break their output pipe.
        process.standardOutput = handle; process.standardError = handle
        do { try process.run(); try? input.fileHandleForReading.close(); try? handle.close(); output = nil }
        catch { closeInput(); try? handle.close(); output = nil; throw error }
    }
    func sendPassword(_ password: String, promptCount: Int) throws {
        guard process.isRunning, promptCount > submittedPrompts, !password.isEmpty, !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else { throw problem("Введите пароль администратора в защищённое поле.") }
        var data = Data(password.utf8); data.append(10)
        defer { data.resetBytes(in: 0..<data.count) }
        try input.fileHandleForWriting.write(contentsOf: data)
        submittedPrompts = promptCount
    }
    func closeInput() { try? input.fileHandleForWriting.close() }
}
