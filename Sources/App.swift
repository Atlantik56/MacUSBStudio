import AppKit
import UniformTypeIdentifiers

var previewPath: String?
var consoleTestRequested = false
final class WindowBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

final class Studio: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let support = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mac USB Studio")
    var state: URL { support.appendingPathComponent("clean-v2") }
    var window: NSWindow!, timer: Timer?
    let route = NSSegmentedControl(labels: ["Скачать macOS", "Готовый установщик"], trackingMode: .selectOne, target: nil, action: nil)
    let choose = NSButton(title: "Выбрать установщик…", target: nil, action: nil)
    let sourceLabel = NSTextField(wrappingLabelWithString: "Выберите Install macOS … .app, InstallAssistant.pkg или DMG с полным установщиком.")
    let versions = NSPopUpButton(frame: .zero, pullsDown: false), usbMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let catalogButton = NSButton(title: "Обновить каталог", target: nil, action: nil), refreshUSB = NSButton(title: "Обновить USB", target: nil, action: nil)
    let download = NSButton(title: "Скачать", target: nil, action: nil), pause = NSButton(title: "Пауза", target: nil, action: nil)
    let write = NSButton(title: "Создать загрузочную флешку…", target: nil, action: nil), journal = NSButton(title: "Открыть журнал", target: nil, action: nil)
    let eject = NSButton(title: "Безопасно извлечь флешку", target: nil, action: nil)
    let catalogLabel = NSTextField(wrappingLabelWithString: "Пять последних поколений · каталог Apple")
    let status = NSTextField(wrappingLabelWithString: "Выберите поколение macOS и нажмите «Скачать»"), detail = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator(), logs = NSTextView()
    let password = NSSecureTextField(), submitPassword = NSButton(title: "Продолжить", target: nil, action: nil), cancelPassword = NSButton(title: "Отмена", target: nil, action: nil)
    var passwordPane: NSStackView!, consoleSession: ConsoleSession?, consoleTest = false, currentPromptCount = 0
    var localPane: NSStackView!, onlinePane: NSStackView!
    var releases = [Release](), usbs = [USB](), selectedSource: Source?
    var busy = false, catalogBusy = false, disksBusy = false, verifying = false, paused = false
    var curl: Process?, curlHandle: FileHandle?, saved: SavedDownload?, samples = [(Date, Int64)]()
    var job: URL?, jobStarted: Date?, polling = false, lastLog = "", stoppedSeen: Date?, recording = false
    var completedJob: URL?, completedUSB: USB?, ejecting = false, ejected = false

    func applicationDidFinishLaunching(_ note: Notification) {
        do { try files.createDirectory(at: state, withIntermediateDirectories: true) } catch { print(error) }
        makeWindow(); makeMenu()
        if let preview = previewPath {
            releases = (try? readJSON([Release].self, Bundle.main.path(forResource: "releases", ofType: "json") ?? "")) ?? []; populateVersions()
            usbMenu.addItem(withTitle: "Выберите USB — данные на нём будут удалены"); controls()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let view = self.window.contentView!; view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: preview)) }
                NSApp.terminate(nil)
            }; return
        }
        restore(); controls()
        if !busy && !consoleTestRequested { refreshDisks(); refreshCatalog() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if consoleTestRequested { window.title = "Mac USB Studio — тест встроенной консоли"; DispatchQueue.main.async { self.startConsoleTest() } }
    }
    func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField { let t = NSTextField(labelWithString: text); t.font = .systemFont(ofSize: size, weight: weight); return t }
    func row(_ views: [NSView]) -> NSStackView { let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 10; s.alignment = .centerY; return s }
    func column(_ views: [NSView]) -> NSStackView { let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = .leading; s.spacing = 10; return s }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac USB Studio"; window.minSize = NSSize(width: 850, height: 740); window.center(); window.delegate = self
        window.contentView = WindowBackground(frame: NSRect(x: 0, y: 0, width: 900, height: 790))
        let root = column([]); root.spacing = 16; root.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        func wide(_ v: NSView) { root.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true }
        root.addArrangedSubview(label("Создать установочную флешку", size: 25, weight: .semibold))
        let intro = label("Установщик Apple → выбранный USB → готовый носитель", size: 13); intro.textColor = .secondaryLabelColor; root.addArrangedSubview(intro)
        root.addArrangedSubview(label("1. Откуда взять macOS", size: 16, weight: .semibold))
        route.selectedSegment = 0; route.target = self; route.action = #selector(changeRoute); root.addArrangedSubview(route)
        choose.target = self; choose.action = #selector(chooseSource)
        catalogButton.target = self; catalogButton.action = #selector(refreshCatalog); versions.target = self; versions.action = #selector(changeVersion)
        download.target = self; download.action = #selector(startDownload); pause.target = self; pause.action = #selector(pauseDownload)
        localPane = column([choose, sourceLabel]); wide(localPane); localPane.isHidden = true
        onlinePane = column([row([versions, catalogButton]), catalogLabel, row([download, pause])]); wide(onlinePane)
        versions.widthAnchor.constraint(greaterThanOrEqualToConstant: 410).isActive = true
        root.addArrangedSubview(label("2. На какую флешку записать", size: 16, weight: .semibold))
        refreshUSB.target = self; refreshUSB.action = #selector(refreshDisks); usbMenu.target = self; usbMenu.action = #selector(selectionChanged)
        usbMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true; wide(row([usbMenu, refreshUSB]))
        let note = NSTextField(wrappingLabelWithString: consoleTestRequested ? "Тест создаёт и удаляет один временный файл на готовом USB. Форматирования и запуска установщика не будет. Пароль вводится в защищённом поле под журналом." : "Все данные выбранного USB будут удалены. Вывод записи и защищённое поле пароля появятся здесь. Разрешите Mac USB Studio доступ к съёмному тому, если macOS спросит.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12); wide(note)
        write.target = self; write.action = #selector(startRecording); write.contentTintColor = .controlAccentColor
        journal.target = self; journal.action = #selector(openJournal); root.addArrangedSubview(row([write, journal]))
        let separator = NSBox(); separator.boxType = .separator; wide(separator)
        status.font = .systemFont(ofSize: 15, weight: .semibold); wide(status)
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 100; progress.isIndeterminate = false; wide(progress)
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); detail.textColor = .secondaryLabelColor; wide(detail)
        eject.target = self; eject.action = #selector(ejectUSB); eject.isHidden = true; root.addArrangedSubview(eject)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        logs.isEditable = false; logs.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logs.frame = NSRect(x: 0, y: 0, width: 844, height: 175)
        logs.minSize = NSSize(width: 0, height: 175); logs.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logs.isVerticallyResizable = true; logs.isHorizontallyResizable = false; logs.autoresizingMask = [.width]
        logs.textContainerInset = NSSize(width: 6, height: 6)
        logs.textContainer?.containerSize = NSSize(width: 844, height: CGFloat.greatestFiniteMagnitude); logs.textContainer?.widthTracksTextView = true
        scroll.documentView = logs
        wide(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 175).isActive = true
        password.placeholderString = "Пароль администратора"; password.target = self; password.action = #selector(sendPassword); password.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        submitPassword.target = self; submitPassword.action = #selector(sendPassword)
        cancelPassword.target = self; cancelPassword.action = #selector(cancelAuthorization)
        passwordPane = row([label("Пароль:", size: 13), password, submitPassword, cancelPassword]); wide(passwordPane); passwordPane.isHidden = true
        for b in [choose, catalogButton, download, pause, refreshUSB, write, journal, eject, submitPassword, cancelPassword] { b.bezelStyle = .rounded }
    }
    func makeMenu() {
        let bar = NSMenu(), appItem = NSMenuItem(); bar.addItem(appItem); let menu = NSMenu(); appItem.submenu = menu
        menu.addItem(withTitle: "О Mac USB Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "Завершить Mac USB Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(title: "Файл", action: nil, keyEquivalent: ""); file.submenu = NSMenu(); bar.addItem(file)
        for (title, action) in [("Папка загрузок", #selector(openDownloads)), ("Журнал операции", #selector(openJournal)), ("Инструкция Apple", #selector(openHelp))] { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; file.submenu!.addItem(i) }
        let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); edit.submenu = NSMenu(); bar.addItem(edit)
        for (title, action, key) in [("Копировать", #selector(NSText.copy(_:)), "c"), ("Вставить", #selector(NSText.paste(_:)), "v"), ("Выбрать всё", #selector(NSText.selectAll(_:)), "a")] { edit.submenu!.addItem(withTitle: title, action: action, keyEquivalent: key) }
        NSApp.mainMenu = bar
    }
    func append(_ text: String) { logs.string += text + "\n"; logs.scrollToEndOfDocument(nil) }
    func showError(_ error: Error) { status.stringValue = error.localizedDescription; append(error.localizedDescription); setProgress(nil, spinning: false) }
    func setProgress(_ value: Double?, spinning: Bool = true) { progress.stopAnimation(nil); progress.isIndeterminate = value == nil && spinning; if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.doubleValue = value ?? 0 } }
    func controls() {
        let idle = !busy && curl == nil && !verifying && !ejecting
        route.isEnabled = idle; choose.isEnabled = idle; versions.isEnabled = idle && !catalogBusy; catalogButton.isEnabled = idle && !catalogBusy
        refreshUSB.isEnabled = idle && !disksBusy; usbMenu.isEnabled = idle && !disksBusy
        write.isEnabled = idle && selectedSource != nil && usbs.indices.contains(usbMenu.indexOfSelectedItem - 1)
        download.isEnabled = idle && releases.indices.contains(versions.indexOfSelectedItem); pause.isEnabled = curl != nil && !paused
        eject.isHidden = completedUSB == nil && !ejected; eject.isEnabled = idle && completedUSB != nil
        eject.title = ejected ? "Флешка извлечена" : "Безопасно извлечь флешку"
        eject.toolTip = completedUSB.map { "Извлечь записанный USB: " + $0.label }
        if releases.indices.contains(versions.indexOfSelectedItem), let s = saved, s.release.id == releases[versions.indexOfSelectedItem].id, fileBytes(s.path) > 0 { download.title = fileBytes(s.path) == s.release.size ? "Использовать скачанное" : "Возобновить загрузку" } else { download.title = "Скачать" }
    }
    func restore() {
        releases = (try? readJSON([Release].self, state.appendingPathComponent("releases.json").path)) ?? (try? readJSON([Release].self, Bundle.main.path(forResource: "releases", ofType: "json") ?? "")) ?? []
        populateVersions(); catalogLabel.stringValue = "Сохранённый каталог · обновляется при подключении к Apple"
        saved = (try? readJSON(SavedDownload.self, state.appendingPathComponent("download.json").path)) ?? (try? readJSON(SavedDownload.self, support.appendingPathComponent("download.json").path))
        if let s = saved, officialURL(s.release.url), s.path.hasPrefix(support.appendingPathComponent("downloads").path + "/"), s.release.size > 0, fileBytes(s.path) > 0 {
            if !releases.contains(where: { $0.id == s.release.id }) { releases.append(s.release); populateVersions() }
            versions.selectItem(at: releases.firstIndex(where: { $0.id == s.release.id }) ?? 0)
            append("Сохранённый установщик: \(s.release.name) \(s.release.version), \(readableBytes(fileBytes(s.path))). Доступен во вкладке «Скачать macOS».")
        } else { saved = nil }
        let savedPath = try? readJSON(String.self, state.appendingPathComponent("active-job.json").path)
        let validatedPath = savedPath.flatMap { try? checkedJobDirectory($0) }
        let activePath = validatedPath ?? recoverRecordingJob()
        let completedPath = (try? readJSON(String.self, state.appendingPathComponent("completed-job.json").path)).flatMap { try? checkedJobDirectory($0) }
        if let path = activePath ?? completedPath {
            job = URL(fileURLWithPath: path); busy = true; recording = true; jobStarted = Date(); status.stringValue = "Восстанавливаю состояние записи…"
            try? save(path, state.appendingPathComponent("active-job.json").path)
            if let item = try? readJSON(RecordingJob.self, path + "/job.json") {
                usbs = [item.usb]; usbMenu.addItem(withTitle: "Выберите USB — данные на нём будут удалены"); usbMenu.addItem(withTitle: item.usb.label); usbMenu.selectItem(at: 1)
                consoleTest = item.kind == "console-test"
                route.selectedSegment = 1; localPane.isHidden = false; onlinePane.isHidden = true; sourceLabel.stringValue = consoleTest ? "Тест встроенной консоли — установщик не запускается" : item.source
            }
            detail.stringValue = "Запись продолжается. Не отключайте USB до завершения."
            if activePath == nil, let result = try? readJSON(RecordingResult.self, path + "/result.json"), result.success {
                lastLog = (try? Data(contentsOf: URL(fileURLWithPath: path + "/write.log"))).map { String(decoding: $0, as: UTF8.self) } ?? ""; logs.string = consoleText(lastLog); logs.scrollToEndOfDocument(nil)
                finish(result); return
            }
            setProgress(nil); tick()
        }
    }
    func populateVersions() { versions.removeAllItems(); releases.forEach { versions.addItem(withTitle: "\($0.name) \($0.version) · \(readableBytes($0.size))") } }
    @objc func refreshCatalog() {
        guard !catalogBusy, !busy, curl == nil, !verifying else { return }; catalogBusy = true; catalogLabel.stringValue = "Получаю последние пять поколений из каталога Apple…"; controls()
        let temp = URL(fileURLWithPath: "/private/tmp/mac-usb-catalog2-" + UUID().uuidString)
        DispatchQueue.global().async {
            let result = Result { try readCatalog(temp) }; try? files.removeItem(at: temp)
            DispatchQueue.main.async {
                self.catalogBusy = false
                switch result {
                case .success(let list):
                    let selectedID = self.releases.indices.contains(self.versions.indexOfSelectedItem) ? self.releases[self.versions.indexOfSelectedItem].id : nil
                    self.releases = list; self.populateVersions(); if let id = selectedID, let n = list.firstIndex(where: { $0.id == id }) { self.versions.selectItem(at: n) }
                    try? save(list, self.state.appendingPathComponent("releases.json").path); self.catalogLabel.stringValue = "Пять последних поколений · каталог Apple обновлён"
                case .failure(let error): self.catalogLabel.stringValue = "Сохранённый каталог · обновление недоступно"; self.append("Каталог: " + error.localizedDescription)
                }
                self.controls()
            }
        }
    }
    @objc func refreshDisks() {
        guard !busy, !disksBusy, curl == nil, !verifying else { return }; disksBusy = true; controls()
        DispatchQueue.global().async { let result = Result { try connectedUSBs() }; DispatchQueue.main.async {
            self.disksBusy = false; self.usbMenu.removeAllItems(); self.usbMenu.addItem(withTitle: "Выберите USB — данные на нём будут удалены")
            switch result { case .success(let list): self.usbs = list; list.forEach { self.usbMenu.addItem(withTitle: $0.label) }; case .failure(let error): self.usbs = []; self.append(error.localizedDescription) }; self.controls()
        } }
    }
    @objc func selectionChanged() { controls() }
    @objc func changeRoute() { localPane.isHidden = route.selectedSegment != 1; onlinePane.isHidden = route.selectedSegment != 0; selectedSource = nil; status.stringValue = route.selectedSegment == 0 ? "Выберите поколение macOS и нажмите «Скачать»" : "Выберите установщик macOS"; setProgress(0); detail.stringValue = ""; controls() }
    @objc func changeVersion() { selectedSource = nil; setProgress(0); detail.stringValue = ""; controls() }
    @objc func chooseSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle, UTType(filenameExtension: "pkg")!, .diskImage]
        panel.message = "Выберите полный установщик macOS от Apple"; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { r in if r == .OK, let url = panel.url { self.inspectSource(url) } }
    }
    func inspectSource(_ url: URL) {
        busy = true; selectedSource = nil; status.stringValue = "Проверяю установщик и подпись Apple…"; setProgress(nil); controls()
        DispatchQueue.global().async {
            let result = Result { () throws -> Source in
                var candidate = url, mount: String?
                do {
                    if url.pathExtension.lowercased() == "dmg" {
                        let data = try execute("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-plist", url.path]).data
                        let p = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
                        let mounts = (p["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
                        guard mounts.count == 1 else { for m in mounts { _ = try? execute("/usr/bin/hdiutil", ["detach", m]) }; throw problem("DMG должен содержать один том с установщиком") }; mount = mounts[0]
                        let candidates = try files.contentsOfDirectory(at: URL(fileURLWithPath: mounts[0]), includingPropertiesForKeys: nil).filter { ["app", "pkg"].contains($0.pathExtension.lowercased()) }
                        guard candidates.count == 1 else { throw problem("В DMG должен находиться один полный установщик .app или InstallAssistant.pkg") }; candidate = candidates[0]
                    }
                    if candidate.pathExtension.lowercased() == "app" { try checkInstaller(candidate.path); return Source(url: candidate, kind: "app", installedApp: candidate.path, imageMount: mount) }
                    if candidate.pathExtension.lowercased() == "pkg" { return Source(url: candidate, kind: "pkg", installedApp: try checkPackage(candidate.path), imageMount: mount) }
                    throw problem("Поддерживаются .app, InstallAssistant.pkg и DMG с полным установщиком")
                } catch { if let m = mount { _ = try? execute("/usr/bin/hdiutil", ["detach", m]) }; throw error }
            }
            DispatchQueue.main.async { self.busy = false; self.setProgress(0); switch result { case .success(let source): self.accept(source); case .failure(let error): self.showError(error) }; self.controls() }
        }
    }
    func accept(_ source: Source) { selectedSource = source; sourceLabel.stringValue = source.url.path; status.stringValue = "Установщик проверен. Выберите USB."; append("Подпись Apple проверена: " + source.url.lastPathComponent); controls() }
    @objc func startDownload() {
        guard !busy, !verifying, curl == nil, releases.indices.contains(versions.indexOfSelectedItem) else { return }
        let release = releases[versions.indexOfSelectedItem]
        do {
            guard officialURL(release.url), release.size > 0 else { throw problem("Некорректный источник установщика") }
            let folder = support.appendingPathComponent("downloads/" + release.id); try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("InstallAssistant.pkg").path, size = fileBytes(path)
            guard size <= release.size else { throw problem("Сохранённый пакет больше ожидаемого. Проверьте файл в папке загрузок.") }
            let item = SavedDownload(release: release, path: path); saved = item; try save(item, state.appendingPathComponent("download.json").path)
            if size == release.size { verifyDownloaded(item); return }
            let free = (try files.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard free > release.size - size + 1_000_000_000 else { throw problem("Недостаточно места для загрузки") }
            let log = folder.appendingPathComponent("download-v2.log"); files.createFile(atPath: log.path, contents: nil); curlHandle = try FileHandle(forWritingTo: log)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); p.arguments = transferArguments(release.url, path, resume: true); p.standardOutput = curlHandle; p.standardError = curlHandle
            curl = p; paused = false; selectedSource = nil; samples = [(Date(), size)]; status.stringValue = "Скачиваю \(release.name) \(release.version)"
            p.terminationHandler = { process in DispatchQueue.main.async {
                guard self.curl === process else { return }; self.curl = nil; try? self.curlHandle?.close(); self.curlHandle = nil
                if self.paused { self.status.stringValue = "Загрузка на паузе. Скачанная часть сохранена." }
                else if process.terminationStatus == 0, fileBytes(path) == release.size { self.verifyDownloaded(item) }
                else { self.status.stringValue = "Загрузка прервалась. Нажмите «Возобновить загрузку»."; self.append((try? String(contentsOf: log, encoding: .utf8)) ?? "Ошибка загрузки") }
                self.controls()
            } }
            try p.run(); controls()
        } catch { curl = nil; try? curlHandle?.close(); curlHandle = nil; showError(error); controls() }
    }
    @objc func pauseDownload() { guard let p = curl else { return }; paused = true; p.terminate(); controls() }
    func verifyDownloaded(_ item: SavedDownload) {
        verifying = true; status.stringValue = "Скачано 100%. Проверяю подпись Apple…"; setProgress(100); controls()
        DispatchQueue.global().async { let result = Result { try checkPackage(item.path) }; DispatchQueue.main.async {
            self.verifying = false
            switch result { case .success(let app): self.accept(Source(url: URL(fileURLWithPath: item.path), kind: "pkg", installedApp: app, imageMount: nil)); self.detail.stringValue = "Загрузка завершена · \(readableBytes(item.release.size)) · подпись Apple проверена"; case .failure(let error): self.selectedSource = nil; self.showError(error) }; self.controls()
        } }
    }
    func tick() {
        if curl != nil, let item = saved {
            let now = Date(), size = fileBytes(item.path); samples.append((now, size)); samples = samples.filter { now.timeIntervalSince($0.0) < 15 }
            let first = samples.first!, elapsed = now.timeIntervalSince(first.0), speed = elapsed > 1 ? max(0, Double(size - first.1) / elapsed) : 0
            let percent = min(100, Double(size) / Double(item.release.size) * 100); setProgress(percent)
            var text = String(format: "%.1f%%", percent) + " · \(readableBytes(size)) / \(readableBytes(item.release.size)) · \(readableBytes(Int64(speed)))/с"
            if speed > 1024 { let seconds = Double(item.release.size - size) / speed; let mins = max(1, Int(ceil(seconds / 60))); text += " · осталось ≈ \(mins) мин · до " + DateFormatter.localizedString(from: now.addingTimeInterval(seconds), dateStyle: .none, timeStyle: .short) }
            detail.stringValue = text
        }
        if recording, let directory = job, !polling { pollRecording(directory) }
    }
    @objc func startRecording() {
        guard !busy, !verifying, curl == nil, let source = selectedSource, usbs.indices.contains(usbMenu.indexOfSelectedItem - 1) else { return }
        let usb = usbs[usbMenu.indexOfSelectedItem - 1], alert = NSAlert()
        alert.messageText = "Стереть этот USB и записать macOS?"; alert.alertStyle = .warning
        alert.informativeText = "\(usb.label)\n\nУстановщик: \(source.url.lastPathComponent)\n\nВсе разделы и данные выбранной флешки будут удалены.\n\nПароль администратора вводится в защищённом поле этого окна. Разрешите Mac USB Studio доступ к съёмным томам, если macOS спросит.\n\nПакет InstallAssistant извлечёт приложение в Applications. Установка самой macOS на этот Mac не запускается."
        alert.addButton(withTitle: "Стереть и записать"); alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { self.prepare(usb, source) } }
    }
    func prepare(_ usb: USB, _ source: Source) {
        consoleTest = false
        completedJob = nil; completedUSB = nil; ejected = false; try? files.removeItem(at: state.appendingPathComponent("completed-job.json"))
        busy = true; job = nil; lastLog = ""; logs.string = ""; status.stringValue = "Подготавливаю установщик для записи…"; detail.stringValue = "Копирование во временную папку. Это может занять несколько минут."; setProgress(nil); controls()
        let directory = URL(fileURLWithPath: "/private/tmp/mac-usb-studio2-" + UUID().uuidString)
        DispatchQueue.global().async {
            let result = Result { () throws -> URL in
                try ensureNoOtherRecorder(); try validate(usb)
                guard usb.size >= 24_000_000_000 else { throw problem("Нужен USB от 24 ГБ. Рекомендуется 32 ГБ или больше.") }
                try files.createDirectory(at: directory, withIntermediateDirectories: false)
                let bytes = try treeSize(source.url), extra: Int64 = source.kind == "pkg" ? max(bytes, 20_000_000_000) : 0
                let free = (try files.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                guard free > bytes + extra + 2_000_000_000 else { throw problem("Для подготовки нужно примерно \(readableBytes(bytes + extra + 2_000_000_000)) свободного места на Mac") }
                let destination = directory.appendingPathComponent(source.kind == "pkg" ? "InstallAssistant.pkg" : source.url.lastPathComponent)
                try execute("/usr/bin/ditto", [source.url.path, destination.path])
                let installed: String
                if source.kind == "pkg" { installed = try checkPackage(destination.path); guard installed == source.installedApp else { throw problem("Пакет установщика изменился") } }
                else { installed = destination.path; try checkInstaller(installed) }
                let job = RecordingJob(usb: usb, source: destination.path, kind: source.kind, installedApp: installed, sourceBytes: fileBytes(destination.path)); try save(job, directory.appendingPathComponent("job.json").path)
                let bundled = Bundle.main.bundlePath + "/Contents/Helpers/MacUSBRecorder", worker = directory.appendingPathComponent("MacUSBRecorder").path
                try signature(bundled); try files.copyItem(atPath: bundled, toPath: worker); try signature(worker)
                guard try execute(worker, ["--self-check"]).text.contains("MAC_USB_RECORDER_2_OK") else { throw problem("Проверка отдельного процесса записи не пройдена") }
                try self.prepareConsoleScript(directory, usb.label)
                try validate(usb); return directory
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let path): self.startConsole(path)
                case .failure(let error): self.busy = false; self.showError(error)
                }; self.controls()
            }
        }
    }
    func prepareConsoleScript(_ directory: URL, _ label: String, test: Bool = false) throws {
        try save("embedded", directory.appendingPathComponent("launch-mode.json").path)
        let script = embeddedLauncherPath(directory.path)
        try embeddedLauncher(directory.path, label, test: test).write(toFile: script, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)
    }
    func startConsole(_ directory: URL) {
        job = directory; recording = true; busy = true; jobStarted = Date(); stoppedSeen = nil; currentPromptCount = 0
        try? save(directory.path, state.appendingPathComponent("active-job.json").path)
        status.stringValue = "Запускаю встроенную консоль…"; detail.stringValue = "Пароль вводится только в защищённом поле. Он не сохраняется в журнале."
        let session = ConsoleSession(); consoleSession = session
        do { try session.start(directory.path); tick() }
        catch { finish(RecordingResult(success: false, message: "Не удалось запустить встроенную консоль: " + error.localizedDescription, mount: nil)) }
        controls()
    }
    func updatePasswordPrompt(_ snapshot: RecordingSnapshot) {
        currentPromptCount = passwordPromptCount(lastLog)
        let pending = snapshot.workerPID == nil && consoleSession?.process.isRunning == true && currentPromptCount > (consoleSession?.submittedPrompts ?? 0)
        let wasHidden = passwordPane.isHidden; passwordPane.isHidden = !pending
        password.isEnabled = pending; submitPassword.isEnabled = pending; cancelPassword.isEnabled = pending; submitPassword.keyEquivalent = pending ? "\r" : ""
        if pending {
            status.stringValue = currentPromptCount > 1 ? "Пароль не принят. Введите его ещё раз." : "Введите пароль администратора в поле под журналом"
            detail.stringValue = "Пароль передаётся локальному sudo и не сохраняется."
            if wasHidden { window.makeFirstResponder(password) }
        }
    }
    @objc func sendPassword() {
        guard !passwordPane.isHidden, let session = consoleSession else { return }
        let value = password.stringValue; password.stringValue = ""
        do {
            try session.sendPassword(value, promptCount: currentPromptCount)
            passwordPane.isHidden = true; submitPassword.keyEquivalent = ""; status.stringValue = "Проверяю пароль администратора…"
        } catch { detail.stringValue = error.localizedDescription; window.makeFirstResponder(password) }
    }
    @objc func cancelAuthorization() {
        guard !passwordPane.isHidden, let directory = job, !files.fileExists(atPath: directory.appendingPathComponent("worker.pid").path) else { return }
        password.stringValue = ""; passwordPane.isHidden = true; submitPassword.keyEquivalent = ""; consoleSession?.closeInput(); status.stringValue = "Отменяю запрос пароля…"
    }
    func startConsoleTest() {
        guard !busy, !verifying, curl == nil, let usb = completedUSB else { showError(problem("Для теста нужна подключённая флешка из последней успешно завершённой записи.")); return }
        busy = true; consoleTest = true; lastLog = ""; logs.string = ""; sourceLabel.stringValue = "Тест встроенной консоли — установщик не запускается"; status.stringValue = "Подготавливаю тест встроенной консоли…"; detail.stringValue = "Проверяю права администратора и доступ к USB без форматирования."; setProgress(nil); controls()
        let directory = URL(fileURLWithPath: "/private/tmp/mac-usb-studio2-" + UUID().uuidString)
        DispatchQueue.global().async {
            let result = Result { () throws -> URL in
                try ensureNoOtherRecorder(); try validate(usb); try files.createDirectory(at: directory, withIntermediateDirectories: false)
                try save(RecordingJob(usb: usb, source: "", kind: "console-test", installedApp: "", sourceBytes: 0), directory.appendingPathComponent("job.json").path)
                let bundled = Bundle.main.bundlePath + "/Contents/Helpers/MacUSBRecorder", worker = directory.appendingPathComponent("MacUSBRecorder").path
                try signature(bundled); try files.copyItem(atPath: bundled, toPath: worker); try signature(worker)
                try self.prepareConsoleScript(directory, usb.label, test: true); return directory
            }
            DispatchQueue.main.async { switch result { case .success(let path): self.startConsole(path); case .failure(let error): self.busy = false; self.consoleTest = false; self.showError(error); self.controls() } }
        }
    }
    func pollRecording(_ directory: URL) {
        polling = true
        DispatchQueue.global().async {
            let snapshot = RecordingSnapshot(directory.path)
            DispatchQueue.main.async {
                self.polling = false; guard self.job == directory, self.recording else { return }
                if let log = snapshot.log, log != self.lastLog { self.lastLog = log; self.logs.string = consoleText(log); self.logs.scrollToEndOfDocument(nil) }
                if let r = snapshot.result { self.finish(r); return }
                if let code = snapshot.exitCode, snapshot.worker == .exited, !snapshot.writerRunning, !snapshot.pidReadFailed {
                    self.finish(RecordingResult(success: false, message: snapshot.workerPID == nil ? "Пароль администратора не получен. Запись не запускалась." : "Процесс записи завершился без результата (код \(code)). Журнал сохранён.", mount: nil)); return
                }
                if snapshot.confirmedStopped(elapsed: Date().timeIntervalSince(self.jobStarted ?? Date())) {
                    if let first = self.stoppedSeen, Date().timeIntervalSince(first) > 5 { self.finish(RecordingResult(success: false, message: "Процесс записи завершился. Журнал сохранён; новая запись автоматически не запускается.", mount: nil)); return }
                    if self.stoppedSeen == nil { self.stoppedSeen = Date() }
                } else { self.stoppedSeen = nil }
                let current = recordingProgress(self.lastLog); self.status.stringValue = current.title; self.setProgress(current.percent)
                if let error = snapshot.logError { self.detail.stringValue = "Не удалось обновить журнал: " + error }
                else if snapshot.worker == .unknown || snapshot.launcher == .unknown { self.detail.stringValue = "Не удалось проверить процесс. Продолжаю следить за журналом; запись не прерывается." }
                else { self.detail.stringValue = "Запись выполняется. Не отключайте USB до завершения." }
                self.updatePasswordPrompt(snapshot)
            }
        }
    }
    func finish(_ result: RecordingResult) {
        consoleSession?.closeInput(); consoleSession = nil; password.stringValue = ""; passwordPane.isHidden = true; submitPassword.keyEquivalent = ""
        busy = false; recording = false; status.stringValue = result.message; setProgress(result.success ? 100 : nil, spinning: false)
        if consoleTest {
            consoleTest = false; detail.stringValue = "Проверка завершена. Установщик не запускался; форматирования не было."
            try? files.removeItem(at: state.appendingPathComponent("active-job.json")); controls(); return
        }
        completedJob = nil; completedUSB = nil; ejected = false
        if result.success {
            if let directory = job, let item = try? readJSON(RecordingJob.self, directory.appendingPathComponent("job.json").path) {
                completedJob = directory; completedUSB = item.usb; try? save(directory.path, state.appendingPathComponent("completed-job.json").path)
            }
            detail.stringValue = "Нажмите «Безопасно извлечь флешку», затем отключите USB. Apple Silicon: кнопка питания. Intel: Option."
        }
        else { detail.stringValue = "Откройте журнал для подробностей." }
        try? files.removeItem(at: state.appendingPathComponent("active-job.json")); controls()
    }
    @objc func ejectUSB() {
        guard !busy, !verifying, curl == nil, !ejecting, !recording, let directory = completedJob, completedUSB != nil else { return }
        ejecting = true; status.stringValue = "Безопасно извлекаю записанную флешку…"; detail.stringValue = "Дождитесь подтверждения перед отключением USB."; controls()
        DispatchQueue.global().async {
            let result = Result { try ejectWrittenUSB(directory.path) }
            DispatchQueue.main.async {
                self.ejecting = false
                switch result {
                case .success(let usb):
                    self.completedJob = nil; self.completedUSB = nil; self.ejected = true; self.selectedSource = nil
                    try? files.removeItem(at: self.state.appendingPathComponent("completed-job.json"))
                    self.status.stringValue = "Флешка безопасно извлечена. Теперь её можно отключить."; self.detail.stringValue = usb.label
                    self.append("USB безопасно извлечён: " + usb.label); self.setProgress(100); self.refreshDisks()
                case .failure(let error):
                    self.status.stringValue = "Не удалось безопасно извлечь флешку."; self.detail.stringValue = error.localizedDescription
                    self.append("Извлечение: " + error.localizedDescription)
                }
                self.controls()
            }
        }
    }
    @objc func openJournal() { NSWorkspace.shared.open(job ?? state) }
    @objc func openDownloads() { let path = support.appendingPathComponent("downloads"); try? files.createDirectory(at: path, withIntermediateDirectories: true); NSWorkspace.shared.open(path) }
    @objc func openHelp() { NSWorkspace.shared.open(URL(string: "https://support.apple.com/en-us/101578")!) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy || verifying || curl != nil || ejecting {
            let alert = NSAlert(); alert.messageText = "Операция ещё выполняется"
            alert.informativeText = ejecting ? "Дождитесь завершения безопасного извлечения USB." : (curl != nil ? "Загрузка будет приостановлена. Сохранённую часть можно возобновить позже." : (job != nil ? "Начавшаяся запись продолжится в фоне. Не отключайте USB. Если пароль ещё не принят, закрытие приложения отменит авторизацию." : "Дождитесь завершения подготовки установщика."))
            alert.addButton(withTitle: "Остаться"); if !ejecting && (curl != nil || job != nil) { alert.addButton(withTitle: "Закрыть приложение") }
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        consoleSession?.closeInput(); password.stringValue = ""; curl?.terminate(); return .terminateNow
    }
}

@main struct Application {
    static func main() {
        consoleTestRequested = CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--test-console"
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-preview" { previewPath = CommandLine.arguments[2] }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--download-arguments" { print(String(decoding: try! JSONEncoder().encode(transferArguments(CommandLine.arguments[2], CommandLine.arguments[3], resume: true)), as: UTF8.self)); return }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--catalog" {
            do { let result = try readCatalog(URL(fileURLWithPath: CommandLine.arguments[2])); print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)); return } catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--recover-recording" { print(recoverRecordingJob() ?? "NO_ACTIVE_RECORDING"); return }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-eject-job" {
            do { let (usb, args) = try checkedEjectionArguments(CommandLine.arguments[2]); print(usb.label); print(args.joined(separator: " ")); return }
            catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--recording-status" {
            do {
                let path = try checkedJobDirectory(CommandLine.arguments[2]), snapshot = RecordingSnapshot(path)
                let progress = recordingProgress(snapshot.log ?? "")
                let output: [String: Any] = ["directory": path, "worker": snapshot.worker.rawValue, "launcher": snapshot.launcher.rawValue, "writerRunning": snapshot.writerRunning, "confirmedStopped": snapshot.confirmedStopped(elapsed: 30), "title": progress.title, "percent": progress.percent as Any? ?? NSNull(), "logBytes": snapshot.log?.utf8.count ?? 0, "logError": snapshot.logError as Any? ?? NSNull(), "complete": snapshot.result?.success as Any? ?? NSNull()]
                print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)); return
            } catch { print(error.localizedDescription); exit(1) }
        }
        let app = NSApplication.shared; app.setActivationPolicy(.regular); let delegate = Studio(); app.delegate = delegate; app.run()
    }
}
