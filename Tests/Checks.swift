import Foundation

@main struct Checks {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) { guard condition() else { fatalError("FAIL: " + name) }; count += 1; print("PASS: " + name) }
        func release(_ version: String) -> Release { Release(id: version, name: "macOS", version: version, build: "", url: "https://swcdn.apple.com/InstallAssistant.pkg", size: 1) }
        let versions = fiveGenerations(["26.1", "26.7.1", "27.0.1", "15.8.1", "14.8.9", "13.7.8", "12.7.6", "15.8"].map(release)).map(\.version)
        check(versions == ["27.0.1", "26.7.1", "15.8.1", "14.8.9", "13.7.8"], "one latest update per generation")
        check(moreRecent("15.10", "15.9"), "numeric version ordering")
        check(officialURL("https://swcdn.apple.com/a.pkg"), "Apple HTTPS accepted")
        for bad in ["http://swcdn.apple.com/a", "https://swcdn.apple.com.evil.test/a", "https://evil.test/a", "https://x@swcdn.apple.com/a"] { check(!officialURL(bad), "untrusted URL rejected") }
        let p = recordingProgress("STAGE: Запись\nErasing disk: 0%... 100%\nCopying essential files...\nCopying to disk: 0%... 10%... 20%...")
        check(p.percent == 20 && p.title.contains("Копирование"), "copy progress distinct from erase progress")
        let erase = recordingProgress("STAGE: Запись\nErasing disk: 0%... 100%")
        check(erase.title.contains("Стирание") && !erase.title.contains("готов"), "erase 100 is not ready")
        let verify = recordingProgress("STAGE: Запись\nCopying to disk: 100%\nSTAGE: Проверка готового носителя")
        check(verify.percent == nil && verify.title.contains("Проверка"), "new phase resets percent")
        check(recordingProgress("") == ProgressState(title: "Запускаю процесс записи…", percent: nil), "empty log waits for recording launcher")
        check(outputIsReady(commandCode: 0, guid: true, hfs: true, bootable: true, physicalMedia: true, installerPayload: true), "successful new installer layout needs no fixed EFI pathname")
        check(!outputIsReady(commandCode: 1, guid: true, hfs: true, bootable: true, physicalMedia: true, installerPayload: true), "failed Apple command cannot be success")
        check(!outputIsReady(commandCode: 0, guid: true, hfs: true, bootable: true, physicalMedia: true, installerPayload: false), "missing payload cannot be success")
        check(!outputIsReady(commandCode: 0, guid: true, hfs: true, bootable: false, physicalMedia: true, installerPayload: true), "nonbootable volume cannot be success")
        let usb = USB(id: "disk99", model: "TEST", registry: "TEST Media", tree: "TEST_PATH", size: 32_000_000_000)
        var info: [String: Any] = ["Internal": false, "WholeDisk": true, "VirtualOrPhysical": "Physical", "BusProtocol": "USB", "Writable": true, "DeviceIdentifier": "disk99", "MediaName": "TEST", "IORegistryEntryName": "TEST Media", "DeviceTreePath": "TEST_PATH", "Size": NSNumber(value: 32_000_000_000 as Int64)]
        check(usb.matches(info), "exact physical USB accepted")
        info["Internal"] = true; check(!usb.matches(info), "internal disk rejected")
        info["Internal"] = false; info["Size"] = NSNumber(value: 64_000_000_000 as Int64); check(!usb.matches(info), "changed capacity rejected")
        info["Size"] = NSNumber(value: usb.size); info["DeviceTreePath"] = "OTHER"; check(!usb.matches(info), "changed physical connection rejected")
        check(quote("a'b") == "'a'\\''b'", "shell quoting apostrophe")
        let script = launcher("/private/tmp/mac-usb-studio2-test ' $()", "TEST USB")
        let temp = "/private/tmp/mac-usb-script-" + UUID().uuidString + ".sh"; try script.write(toFile: temp, atomically: true, encoding: .utf8); defer { try? files.removeItem(atPath: temp) }
        let syntax = try execute("/bin/bash", ["-n", temp]); check(syntax.code == 0, "launcher syntax handles special characters")
        let args = transferArguments("https://swcdn.apple.com/test", "/tmp/test", resume: true)
        check(args.contains("--continue-at") && args.contains("--disable") && args.contains("--noproxy"), "download resumes and ignores user curl config/proxy")
        check(!args.contains("--insecure"), "TLS verification retained")
        let folder = URL(fileURLWithPath: "/private/tmp/mac-usb-model-tests-" + UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? files.removeItem(at: folder) }
        let result = RecordingResult(success: false, message: "Ошибка сохранена", mount: nil); let path = folder.appendingPathComponent("result.json").path
        try save(result, path); let restored = try readJSON(RecordingResult.self, path); check(!restored.success && restored.message == result.message, "recording result persists independently of UI")
        let jobName = "mac-usb-studio2-" + UUID().uuidString, jobPath = "/private/tmp/" + jobName
        try files.createDirectory(atPath: jobPath, withIntermediateDirectories: false); defer { try? files.removeItem(atPath: jobPath) }
        let privatePath = try checkedJobDirectory(jobPath), publicPath = try checkedJobDirectory("/tmp/" + jobName)
        check(privatePath == jobPath && publicPath == privatePath, "private/tmp and tmp identify the same real job")
        let linkPath = "/private/tmp/mac-usb-studio2-" + UUID().uuidString
        try files.createSymbolicLink(atPath: linkPath, withDestinationPath: jobPath); defer { try? files.removeItem(atPath: linkPath) }
        check((try? checkedJobDirectory(linkPath)) == nil, "symlink job rejected")
        check((try? checkedJobDirectory(jobPath + "/../" + jobName)) == nil, "traversal rejected")
        check((try? checkedJobDirectory(folder.path)) == nil, "unrelated temporary directory rejected")
        check(commandMatches("/bin/bash /tmp/" + jobName + "/Записать macOS.command", jobPath + "/Записать macOS.command"), "Terminal tmp alias matches private tmp job")
        check(!commandMatches("/bin/bash /tmp/other/Записать macOS.command", jobPath + "/Записать macOS.command"), "different job cannot match reused PID")
        let launcherPath = jobPath + "/launcher.pid", workerPath = jobPath + "/worker.pid"
        try "123\n".write(toFile: launcherPath, atomically: true, encoding: .utf8)
        let waiting = ProcessSnapshot(commands: [123: "/bin/bash /tmp/" + jobName + "/Записать macOS.command"])
        let waitingStatus = RecordingSnapshot(jobPath, processes: waiting)
        check(waitingStatus.launcher == .running && !waitingStatus.confirmedStopped(elapsed: 180), "password wait stays active beyond old timeout")
        let job = RecordingJob(usb: usb, source: jobPath + "/Install macOS Test.app", kind: "app", installedApp: jobPath + "/Install macOS Test.app", sourceBytes: 0)
        try save(job, jobPath + "/job.json")
        check(recoverRecordingJob(processes: waiting) == jobPath, "active job recovered when UI pointer is missing")
        try "456".write(toFile: workerPath, atomically: true, encoding: .utf8)
        let writing = ProcessSnapshot(commands: [456: "/tmp/" + jobName + "/MacUSBRecorder --write /tmp/" + jobName])
        check(!RecordingSnapshot(jobPath, processes: writing).confirmedStopped(elapsed: 180), "writer continues after launcher closes")
        let orphanedApple = ProcessSnapshot(commands: [789: "/tmp/" + jobName + "/Install macOS Test.app/Contents/Resources/createinstallmedia --volume /Volumes/Test --nointeraction"])
        check(!RecordingSnapshot(jobPath, processes: orphanedApple).confirmedStopped(elapsed: 180), "live Apple writer prevents false stop even with stale worker PID")
        check(!RecordingSnapshot(jobPath, processes: ProcessSnapshot(commands: nil)).confirmedStopped(elapsed: 180), "process inspection failure is not process exit")
        check(RecordingSnapshot(jobPath, processes: ProcessSnapshot(commands: [:])).confirmedStopped(elapsed: 180), "confirmed absent writer is detected")
        try "not a pid".write(toFile: workerPath, atomically: true, encoding: .utf8)
        check(!RecordingSnapshot(jobPath, processes: ProcessSnapshot(commands: [:])).confirmedStopped(elapsed: 180), "unreadable PID does not stop monitoring")
        let partial = "STAGE: Запись\rErasing disk: 100%\rCopying to disk: 0%... 10%... 2"
        check(recordingProgress(partial).percent == 10, "partial percentage and carriage return log are supported")
        for (line, title) in [("Copying essential files...", "служебных"), ("Copying the macOS RecoveryOS...", "восстановления"), ("Making disk bootable...", "загрузки")] {
            let stage = recordingProgress("STAGE: Запись\nErasing disk: 100%\n" + line)
            check(stage.percent == nil && stage.title.contains(title), "Apple phase does not inherit erase 100: " + line)
        }
        let boot = recordingProgress("STAGE: Запись\nCopying to disk: 100%\nMaking disk bootable...")
        check(boot.percent == nil && boot.title.contains("загрузки"), "final boot preparation is not overall completion")
        let ready = recordingProgress("STAGE: Запись\nCopying to disk: 100%\nInstall media now available at /Volumes/Test")
        check(ready.percent == nil && ready.title.contains("Проверяю"), "Apple success awaits recorder validation")
        try Data([0x41, 0xe2, 0x82]).write(to: URL(fileURLWithPath: jobPath + "/write.log"))
        check(RecordingSnapshot(jobPath, processes: writing).log?.hasPrefix("A") == true, "incomplete UTF8 log append does not blank the journal")
        let commandPath = jobPath + "/Записать macOS.command"
        try "read -r\n".write(toFile: commandPath, atomically: true, encoding: .utf8)
        let testProcess = Process(), testInput = Pipe()
        testProcess.executableURL = URL(fileURLWithPath: "/bin/bash"); testProcess.arguments = ["/tmp/" + jobName + "/Записать macOS.command"]; testProcess.standardInput = testInput
        try testProcess.run()
        let liveProcesses = ProcessSnapshot.capture()
        testProcess.terminate(); testProcess.waitUntilExit()
        check(liveProcesses.state(testProcess.processIdentifier, matching: commandPath) == .running, "real ps preserves Cyrillic launcher name and tmp alias")
        try "456".write(toFile: workerPath, atomically: true, encoding: .utf8)
        var ejectDisk = info; ejectDisk["DeviceTreePath"] = usb.tree
        let successful = RecordingResult(success: true, message: "Готово", mount: "/Volumes/Test")
        let finished = RecordingSnapshot(jobPath, processes: ProcessSnapshot(commands: [:]))
        let ejectArgs = try ejectionArguments(usb, result: successful, snapshot: finished, currentDisk: ejectDisk)
        check(ejectArgs == ["eject", "/dev/disk99"] && !ejectArgs.contains("force"), "safe eject targets the recorded whole disk without force")
        check((try? ejectionArguments(usb, result: result, snapshot: finished, currentDisk: ejectDisk)) == nil, "failed recording cannot enable eject")
        check((try? ejectionArguments(usb, result: nil, snapshot: finished, currentDisk: ejectDisk)) == nil, "unfinished recording cannot enable eject")
        check((try? ejectionArguments(usb, result: successful, snapshot: RecordingSnapshot(jobPath, processes: writing), currentDisk: ejectDisk)) == nil, "running recorder cannot be ejected")
        check((try? ejectionArguments(usb, result: successful, snapshot: RecordingSnapshot(jobPath, processes: orphanedApple), currentDisk: ejectDisk)) == nil, "live Apple writer prevents eject")
        check((try? ejectionArguments(usb, result: successful, snapshot: RecordingSnapshot(jobPath, processes: ProcessSnapshot(commands: nil)), currentDisk: ejectDisk)) == nil, "unknown process state prevents eject")
        for (key, value) in [("DeviceIdentifier", "disk98"), ("DeviceTreePath", "NEW_PORT"), ("MediaName", "OTHER"), ("IORegistryEntryName", "OTHER Media")] {
            var changed = ejectDisk; changed[key] = value
            check((try? ejectionArguments(usb, result: successful, snapshot: finished, currentDisk: changed)) == nil, "changed eject target is rejected: " + key)
        }
        var internalDisk = ejectDisk; internalDisk["Internal"] = true
        check((try? ejectionArguments(usb, result: successful, snapshot: finished, currentDisk: internalDisk)) == nil, "internal disk cannot be ejected by completed USB job")
        let embedded = embeddedLauncher(jobPath, usb.label)
        try embedded.write(toFile: embeddedLauncherPath(jobPath), atomically: true, encoding: .utf8)
        let embeddedSyntax = try execute("/bin/bash", ["-n", embeddedLauncherPath(jobPath)])
        check(embeddedSyntax.code == 0, "embedded launcher syntax")
        check(embedded.contains("sudo -S -p") && !embedded.contains("tee") && !embedded.contains("read -r"), "embedded launcher reads sudo stdin and never needs Terminal or final Enter")
        check(!embedded.contains("--console-test") && embedded.contains("--write"), "normal console runs recorder mode")
        let probeScript = embeddedLauncher(jobPath, usb.label, test: true)
        check(probeScript.contains("--console-test") && !probeScript.contains("--write"), "console access test cannot launch recorder mode")
        let prompts = "first " + passwordPromptMarker + " retry " + passwordPromptMarker
        check(passwordPromptCount(prompts) == 2 && passwordPromptCount(String(passwordPromptMarker.dropLast())) == 0, "complete sudo prompts and retries are counted")
        check(!consoleText(prompts).contains(passwordPromptMarker) && consoleText(prompts).contains("поле ниже"), "internal auth markers are replaced in displayed console")
        try save("embedded", jobPath + "/launch-mode.json")
        check(recordingLauncherPath(jobPath) == embeddedLauncherPath(jobPath), "embedded launcher monitoring uses its actual filename")
        let embeddedProcess = ProcessSnapshot(commands: [123: "/bin/bash /tmp/" + jobName + "/record-in-app.sh"])
        check(RecordingSnapshot(jobPath, processes: embeddedProcess).launcher == .running, "embedded password wait is recognized as active")
        let testValue = "local-test-value"
        let fakeScript = """
        printf '%s' '\(passwordPromptMarker)'
        IFS= read -r test_value || exit 7
        printf '\\nAUTH_BYTES=%s\\n' "${#test_value}"
        /bin/sleep 0.1
        printf '%s\\n' 'WRITE_COMPLETE'
        """
        try fakeScript.write(toFile: embeddedLauncherPath(jobPath), atomically: true, encoding: .utf8)
        try Data().write(to: URL(fileURLWithPath: jobPath + "/write.log"))
        let console = ConsoleSession(); try console.start(jobPath)
        var rejected = false
        do { try console.sendPassword("bad\nline", promptCount: 1) } catch { rejected = true }
        check(rejected, "multiline input cannot inject another stdin command")
        try console.sendPassword(testValue, promptCount: 1)
        rejected = false
        do { try console.sendPassword(testValue, promptCount: 1) } catch { rejected = true }
        check(rejected, "one password response per prompt")
        console.closeInput(); console.process.waitUntilExit()
        let consoleLog = try String(contentsOfFile: jobPath + "/write.log", encoding: .utf8)
        check(console.process.terminationStatus == 0 && consoleLog.contains("AUTH_BYTES=\(testValue.utf8.count)"), "protected field sends a line to local child stdin")
        check(!consoleLog.contains(testValue) && !(console.process.arguments ?? []).joined().contains(testValue), "password is neither logged nor placed in process arguments")
        check(consoleLog.contains("WRITE_COMPLETE"), "closing UI input after authorization does not interrupt output to file")
        try "IFS= read -r test_value || exit 7\n".write(toFile: embeddedLauncherPath(jobPath), atomically: true, encoding: .utf8)
        let cancelled = ConsoleSession(); try cancelled.start(jobPath); cancelled.closeInput(); cancelled.process.waitUntilExit()
        check(cancelled.process.terminationStatus == 7, "cancel before authorization closes stdin and stops password wait")
        print("\(count) checks passed; no USB writes performed")
    }
}
