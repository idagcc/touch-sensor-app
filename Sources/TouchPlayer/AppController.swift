import AppKit
import TouchPlayerCore

final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = PlayerEngine()
    let serial = SerialConnection()
    let router = CommandRouter()
    var store: ConfigurationStore
    var config = Configuration()
    var panel: ControlPanel!
    var outputWindow: OutputWindow?
    var outputFullscreen = false
    var connected = false
    var connecting = false
    var wantsConnection = false
    var timer: Timer?
    var keyboardMonitor: Any?
    private var availableDevices: [SerialDevice] = []
    private var ignoredCommands = 0
    private var lastIgnoredLog: UInt64 = 0
    var activity: NSObjectProtocol?
    var hiddenCursor = false
    private var reloadInProgress = false
    private var reloadGeneration = 0
    private var securityScopedURL: URL?
    private var mediaGeneration = 0

    override init() {
        let args = ProcessInfo.processInfo.arguments
        var staleBookmark = false
        let root: URL
        if let index = args.firstIndex(of: "--data-dir"), args.indices.contains(index + 1) {
            root = URL(fileURLWithPath: args[index+1], isDirectory: true)
        } else if let bookmark = UserDefaults.standard.data(forKey: "dataFolderBookmark"),
                  let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &staleBookmark) {
            root = resolved
        } else if let saved = UserDefaults.standard.string(forKey: "dataFolder") {
            root = URL(fileURLWithPath: saved, isDirectory: true)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Touch Player Data")
            if FileManager.default.fileExists(atPath: sibling.path) { root = sibling }
            else {
                root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Touch Player")
                if !FileManager.default.fileExists(atPath: root.path), let seed = Bundle.main.resourceURL?.appendingPathComponent("DefaultData") {
                    try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: seed, to: root)
                }
            }
        } else { root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Touch Player Data") }
        store = ConfigurationStore(root: root)
        super.init()
        if root.startAccessingSecurityScopedResource() { securityScopedURL = root }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        panel = ControlPanel()
        panel.window?.delegate = self
        panel.embed(engine.surface)
        engine.surface.showMessage("Choose your Touch Player Data folder to load videos")
        wireCallbacks()
        refreshPorts()
        serial.refreshDevices()
        panel.rootLabel.stringValue = "DATA FOLDER   \(store.root.path)"
        panel.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Touch Player installation is running")
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command) { return event }
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable { return event }
            if event.keyCode == 53 { self.closeOutput(); return nil }
            if event.isARepeat { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ", "0": self.action(.toggle, source: "Keyboard · single touch"); return nil
            case "1", "r": self.action(.reset, source: "Keyboard · holding video"); return nil
            case "f": self.showOutput(fullscreen: true); return nil
            default: return event
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Show an active window before accessing protected folders so macOS can
        // present its normal file-access prompt without blocking an invisible app.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Bundle.main.bundleURL.pathExtension == "app",
               !ProcessInfo.processInfo.arguments.contains("--data-dir"),
               UserDefaults.standard.string(forKey: "dataFolder") == nil {
                self.chooseDataFolder()
                return
            }
            self.reload {
                if self.config.output.openOnLaunch { self.showOutput(fullscreen: self.config.output.fullscreenOnLaunch) }
                if self.config.serial.autoConnect, !self.config.serial.port.isEmpty { self.wantsConnection = true; self.connect() }
            }
        }
    }

    private func wireCallbacks() {
        engine.onChange = { [weak self] in self?.updatePlayback() }
        engine.onError = { [weak self] message in self?.showError(message) }
        engine.onEvent = { [weak self] message in self?.panel.addLog(message) }
        engine.onQuit = { NSApp.terminate(nil) }
        serial.onCommand = { [weak self] command in
            guard let self else { return }
            if let action = self.router.route(command, configuration: self.config) {
                self.action(action, source: "Serial \(command)")
            } else {
                self.ignoredCommands += 1
                let now = DispatchTime.now().uptimeNanoseconds
                if now - self.lastIgnoredLog >= 1_000_000_000 {
                    self.panel.addLog("Ignored / debounced: \(self.ignoredCommands) · latest: \(command)")
                    self.ignoredCommands = 0
                    self.lastIgnoredLog = now
                }
            }
        }
        serial.onDevicesChanged = { [weak self] devices in
            self?.availableDevices = devices
            self?.refreshPorts()
        }
        serial.onStatus = { [weak self] status in
            guard let self else { return }
            self.connected = status.phase == .connected
            self.connecting = status.phase == .connecting || status.phase == .settling
            self.wantsConnection = status.phase != .disconnected
            self.panel.setConnection(status.phase)
            self.panel.connectionLabel.toolTip = status.message
            self.panel.addLog(status.message)
            if status.phase == .connected {
                self.router.reset()
                if let device = status.device, device.path != self.config.serial.port || device.identity != self.config.serial.deviceIdentity {
                    self.config.serial.port = device.path
                    self.config.serial.deviceIdentity = device.identity
                    do { try self.store.save(self.config) }
                    catch { self.panel.addLog("Could not remember Arduino identity: \(error.localizedDescription)") }
                    self.refreshPorts(selectSaved: true)
                }
            }
        }
        panel.onRefresh = { [weak self] in self?.serial.refreshDevices() }
        panel.onConnect = { [weak self] in
            guard let self else { return }
            if self.connected || self.connecting || self.wantsConnection { self.wantsConnection = false; self.serial.stop() }
            else {
                do {
                    try self.saveSettings(learnDevice: true)
                    guard !self.config.serial.port.isEmpty else { self.showError("Select an Arduino serial port first."); return }
                    self.wantsConnection = true
                    self.connect()
                } catch { self.showError(error.localizedDescription) }
            }
        }
        panel.onApply = { [weak self] in
            guard let self else { return }
            do { try self.saveSettings(); self.loadMedia(); self.panel.addLog("Settings saved") }
            catch { self.showError(error.localizedDescription) }
        }
        panel.onReload = { [weak self] in self?.reload() }
        panel.onOpenFolder = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.store.root.appendingPathComponent("media"))
        }
        panel.onChooseFolder = { [weak self] in self?.chooseDataFolder() }
        panel.onOpenConfig = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.selectFile(self.store.file.path, inFileViewerRootedAtPath: self.store.root.path)
        }
        panel.onOutput = { [weak self] in self?.showOutput(fullscreen: true) }
        panel.onPreview = { [weak self] in self?.showOutput(fullscreen: false) }
        panel.onAction = { [weak self] action in self?.action(action, source: "Control panel") }
    }

    func reload(completion: (() -> Void)? = nil) {
        guard !reloadInProgress else { return }
        reloadInProgress = true
        reloadGeneration += 1
        let token = reloadGeneration
        let loadingStore = store
        panel.addLog("Loading data folder…")
        // File access can wait for a macOS privacy prompt or a slow external disk.
        // Keep the operator panel responsive throughout that wait.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try loadingStore.load() }
            DispatchQueue.main.async { [self] in
                guard reloadGeneration == token else { return }
                reloadInProgress = false
                switch result {
                case .success(let loaded):
                    config = loaded
                    router.reset()
                    fillSettings()
                    loadMedia()
                    panel.addLog("Loaded config.json")
                    serial.configure(config.serial)
                    completion?()
                case .failure(let error): showError("Could not load config.json: \(error.localizedDescription)")
                }
            }
        }
    }

    func loadMedia() {
        mediaGeneration += 1
        let token = mediaGeneration
        let snapshot = config
        let mediaStore = store
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result {
                (try mediaStore.media(in: snapshot.videos.holdingFolder), try mediaStore.media(in: snapshot.videos.playbackFolder))
            }
            DispatchQueue.main.async { [self] in
                guard token == mediaGeneration, snapshot == config, mediaStore.root == store.root else { return }
                switch result {
                case .success(let (holding, playback)):
                    engine.load(config: snapshot, holdingURL: holding.first, playbackURL: playback.first)
                    panel.addLog("Holding: \(holding.first?.lastPathComponent ?? "missing")")
                    panel.addLog("Playback: \(playback.first?.lastPathComponent ?? "missing")")
                    if holding.count > 1 || playback.count > 1 { panel.addLog("Multiple videos in folder: using the first by filename") }
                    if outputWindow != nil { showOutput(fullscreen: outputFullscreen) }
                case .failure(let error): showError("Could not read video folders: \(error.localizedDescription)")
                }
            }
        }
    }

    func fillSettings() {
        refreshPorts(selectSaved: true)
        panel.baud.selectItem(withTitle: String(config.serial.baudRate))
        panel.widthField.stringValue = String(config.output.width)
        panel.heightField.stringValue = String(config.output.height)
        panel.scaling.selectItem(at: ["fit", "fill", "stretch"].firstIndex(of: config.output.scale) ?? 0)
        panel.ending.selectItem(at: ["holding", "freeze", "quit"].firstIndex(of: config.videos.endBehavior) ?? 0)
        panel.toggleCommand.stringValue = command(for: .toggle)
        panel.restartCommand.stringValue = command(for: .restart)
        panel.resetCommand.stringValue = command(for: .reset)
        panel.autoConnect.state = config.serial.autoConnect ? .on : .off
        panel.startupOutput.state = config.output.openOnLaunch && config.output.fullscreenOnLaunch ? .on : .off
        refreshDisplays()
    }

    private func command(for action: PlayerAction) -> String { config.commands.keys.sorted().first { config.commands[$0] == action } ?? "" }

    func saveSettings(learnDevice: Bool = false) throws {
        guard !reloadInProgress else { throw ConfigError.invalid("Data is still loading. If macOS is waiting for folder access, use Choose data folder to select your Touch Player Data folder.") }
        var next = config
        guard let width = Int(panel.widthField.stringValue), let height = Int(panel.heightField.stringValue) else {
            throw ConfigError.invalid("Enter whole numbers for the canvas width and height.")
        }
        next.output.width = width
        next.output.height = height
        next.output.scale = ["fit", "fill", "stretch"][max(0, panel.scaling.indexOfSelectedItem)]
        next.videos.endBehavior = ["holding", "freeze", "quit"][max(0, panel.ending.indexOfSelectedItem)]
        next.output.displayID = panel.displays.selectedItem?.representedObject as? UInt32 ?? 0
        next.output.openOnLaunch = panel.startupOutput.state == .on
        next.output.fullscreenOnLaunch = next.output.openOnLaunch
        next.serial.autoConnect = panel.autoConnect.state == .on
        next.serial.port = panel.ports.selectedItem?.representedObject as? String ?? ""
        if learnDevice || next.serial.port != config.serial.port || next.serial.deviceIdentity == nil {
            next.serial.deviceIdentity = availableDevices.first { $0.path == next.serial.port }?.identity
        }
        next.serial.baudRate = Int(panel.baud.titleOfSelectedItem ?? "9600") ?? 9600
        let mappings: [(String, PlayerAction)] = [(panel.toggleCommand.stringValue, .toggle), (panel.restartCommand.stringValue, .restart), (panel.resetCommand.stringValue, .reset)]
        let nonempty = mappings.map(\.0).filter { !$0.isEmpty }
        guard Set(nonempty).count == nonempty.count else { throw ConfigError.invalid("Each button needs a different command.") }
        // Preserve additional JSON aliases; replace only the primary mapping shown in each field.
        for action in [PlayerAction.toggle, .restart, .reset] {
            if let old = config.commands.keys.sorted().first(where: { config.commands[$0] == action }) { next.commands.removeValue(forKey: old) }
        }
        for (command, action) in mappings where !command.isEmpty {
            if let existing = next.commands[command], existing != action { throw ConfigError.invalid("Command \(command) is already mapped to \(existing.rawValue) in config.json.") }
            next.commands[command] = action
        }
        try store.save(next)
        config = next
        router.reset()
        serial.configure(config.serial)
    }

    func refreshPorts(selectSaved: Bool = false) {
        let selected = panel.ports.selectedItem?.representedObject as? String ?? config.serial.port
        panel.ports.removeAllItems()
        panel.ports.addItem(withTitle: "Select serial port…")
        panel.ports.lastItem?.representedObject = ""
        var ports = availableDevices.map(\.path)
        if !config.serial.port.isEmpty, !ports.contains(config.serial.port) { ports.append(config.serial.port) }
        for path in ports {
            let name = availableDevices.first { $0.path == path }?.name ?? ""
            let shortPath = path.replacingOccurrences(of: "/dev/", with: "")
            panel.ports.addItem(withTitle: name.isEmpty || name == shortPath ? shortPath : "\(name) · \(shortPath)")
            panel.ports.lastItem?.representedObject = path
            panel.ports.lastItem?.toolTip = path
        }
        let desired = selectSaved || selected.isEmpty ? config.serial.port : selected
        if let item = panel.ports.itemArray.first(where: { ($0.representedObject as? String) == desired }) { panel.ports.select(item) }
    }

    func refreshDisplays() {
        panel.displays.removeAllItems()
        panel.displays.addItem(withTitle: "Main display")
        panel.displays.lastItem?.representedObject = UInt32(0)
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            panel.displays.addItem(withTitle: screen.localizedName)
            panel.displays.lastItem?.representedObject = id
        }
        if let item = panel.displays.itemArray.first(where: { ($0.representedObject as? UInt32) == config.output.displayID }) { panel.displays.select(item) }
    }

    @objc func chooseDataFolder() {
        let chooser = NSOpenPanel()
        chooser.title = "Choose your Touch Player Data folder"
        chooser.message = "Select the folder containing config.json and media. This also grants macOS access to that folder."
        chooser.prompt = "Use this folder"
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.directoryURL = store.root
        chooser.beginSheetModal(for: panel.window!) { [weak self] response in
            guard let self, response == .OK, let url = chooser.url else { return }
            self.store = ConfigurationStore(root: url)
            self.securityScopedURL?.stopAccessingSecurityScopedResource()
            self.securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
            UserDefaults.standard.set(url.path, forKey: "dataFolder")
            if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: "dataFolderBookmark")
            } else { UserDefaults.standard.removeObject(forKey: "dataFolderBookmark") }
            self.panel.rootLabel.stringValue = "DATA FOLDER   \(url.path)"
            self.reloadInProgress = false
            self.reload {
                self.wantsConnection = self.config.serial.autoConnect && !self.config.serial.port.isEmpty
                if self.wantsConnection { self.connect() }
                if self.config.output.openOnLaunch { self.showOutput(fullscreen: self.config.output.fullscreenOnLaunch) }
            }
        }
    }

    func connect() {
        guard !config.serial.port.isEmpty, !connecting, !connected else { return }
        connecting = true
        router.reset()
        serial.start(settings: config.serial)
    }

    func action(_ action: PlayerAction, source: String) {
        panel.addLog("\(source) → \(action.rawValue)")
        engine.perform(action)
    }

    func updatePlayback() {
        panel.stateLabel.stringValue = engine.state.rawValue.uppercased()
        switch engine.state {
        case .holding: panel.headline.stringValue = "Ready for the next touch."
        case .playing: panel.headline.stringValue = "Playback in motion."
        case .paused: panel.headline.stringValue = "Paused. Ready when you are."
        case .finished: panel.headline.stringValue = "Playback complete."
        }
        panel.mediaLabel.stringValue = (engine.state == .holding ? engine.holdingURL : engine.playbackURL)?.lastPathComponent ?? "No video loaded"
    }

    func tick() {
        let (time, duration) = engine.timing
        func format(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds)/60, Int(seconds)%60) }
        panel.timeLabel.stringValue = "\(format(time)) / \(format(duration))"
    }

    func showOutput(fullscreen: Bool) {
        let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == config.output.displayID }) ?? NSScreen.screens.first
        guard let screen else { return }
        closeOutput(activatePanel: false)
        outputFullscreen = fullscreen
        let frame: NSRect
        if fullscreen { frame = screen.frame }
        else {
            let factor = min(1, min(screen.visibleFrame.width * 0.85 / CGFloat(config.output.width), screen.visibleFrame.height * 0.85 / CGFloat(config.output.height)))
            let size = CGSize(width: CGFloat(config.output.width)*factor, height: CGFloat(config.output.height)*factor)
            frame = NSRect(x: screen.visibleFrame.midX-size.width/2, y: screen.visibleFrame.midY-size.height/2, width: size.width, height: size.height)
        }
        let window = OutputWindow(contentRect: frame, styleMask: fullscreen ? [.borderless] : [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false, screen: screen)
        window.title = "Touch Player · Output"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        if fullscreen { window.level = .screenSaver }
        engine.surface.removeFromSuperview()
        window.contentView = engine.surface
        engine.surface.translatesAutoresizingMaskIntoConstraints = true
        engine.surface.autoresizingMask = [.width, .height]
        outputWindow = window
        window.makeKeyAndOrderFront(nil)
        if fullscreen { NSCursor.hide(); hiddenCursor = true }
        panel.fullscreenButton.title = "↗  Output is live · Esc to return"
    }

    func closeOutput(activatePanel: Bool = true) {
        if hiddenCursor { NSCursor.unhide(); hiddenCursor = false }
        if let window = outputWindow {
            window.delegate = nil
            engine.surface.removeFromSuperview()
            window.contentView = NSView()
            window.close()
            outputWindow = nil
        }
        panel.embed(engine.surface)
        panel.fullscreenButton.title = "↗  Launch full screen"
        if activatePanel { panel.window?.makeKeyAndOrderFront(nil) }
    }

    @objc func screensChanged() {
        refreshDisplays()
        if outputWindow != nil { showOutput(fullscreen: outputFullscreen) }
    }

    @objc func macWillSleep() { serial.suspend() }
    @objc func macDidWake() { serial.resume() }

    func showError(_ message: String) {
        panel.addLog("⚠ \(message)")
        // Serial playback never opens a blocking dialog over the installation.
        panel.connectionLabel.stringValue = "⚠  See serial activity"
        panel.connectionLabel.toolTip = message
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === outputWindow { closeOutput(); return false }
        NSApp.terminate(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        serial.shutdown()
        engine.stop()
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        if hiddenCursor { NSCursor.unhide() }
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    private func setupMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Touch Player", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Touch Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let chooseItem = NSMenuItem(title: "Choose Data Folder…", action: #selector(chooseDataFolder), keyEquivalent: "o")
        chooseItem.target = self
        fileMenu.addItem(chooseItem)
        fileItem.submenu = fileMenu
        bar.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }
}
