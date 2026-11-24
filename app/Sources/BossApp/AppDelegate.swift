import AppKit
import SwiftUI
import CoreGraphics
import QuartzCore
import BossCore

/// A floating panel that never takes key focus, so typing stays in whatever app Roman is in.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click even though its window is never key.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = BossSettings()
    let paths = BossPaths.fromEnvironment()
    var engine: BossEngine!
    /// False for any test, demo or sandbox instance: those never message the phone.
    var telegramAllowed = false
    var panel: FloatingPanel!
    var chatPanel: ChatPanel?
    let chat = ChatModel()
    static let chatWidth: CGFloat = 700
    var statusItem: NSStatusItem!
    let audio = AudioCapture()
    let preview = LivePreview()
    let hotkey = Hotkey()
    var speech: SpeechOut!
    var sse: SSEClient?
    var debugServer: DebugServer?
    var timers: [Timer] = []
    var lastStatus: AppStatus?
    var wasRecording = false

    static let pillSize = NSSize(width: 420, height: 48)
    static let panelWidth: CGFloat = 420
    /// Height is Roman's: drag the top or bottom edge; remembered across launches.
    static var expandedSize: NSSize {
        let h = UserDefaults.standard.double(forKey: "panelHeight")
        return NSSize(width: panelWidth, height: h >= 240 ? h : 520)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        retireOlderInstances()
        defer { engine?.language = settings.languageLock }
        try? FileManager.default.createDirectory(at: paths.outbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let paths = self.paths
        let token: @Sendable () -> String? = { paths.readToken() }
        speech = SpeechOut(settings: settings)
        let channel = ChannelClient(token: token)
        let store = SessionsStore.fromEnvironment()
        let telegram = TelegramFallback(away: AwayDetector(idleSeconds: {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }), runner: TelegramFallback.shellRunner(log: paths.logs.appendingPathComponent("telegram.log")))
        telegramAllowed = TelegramFallback.allowed(env: ProcessInfo.processInfo.environment,
                                                   defaultHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Boss").path)
        telegram.enabled = settings.telegramFallback && telegramAllowed

        let deps = BossDependencies(
            channel: channel, transcriber: WhisperServerTranscriber(), outbox: Outbox(dir: paths.outbox),
            loadSessions: { store.load() }, ttyLookup: { SessionsStore.psTTY($0) },
            speaker: speech, sounds: Sounds(), recorder: audio, settings: settings, telegram: telegram,
            showSession: { _, tty in ITerm.show(tty: tty) },
            openURL: { if let u = URL(string: $0) { NSWorkspace.shared.open(u) } },
            restartBoss: { _ = BossRestarter.restart() })
        engine = BossEngine(deps: deps)

        setupPanel()
        setupStatusItem()
        setupAudio()
        setupHotkey()
        setupChannel(token: token)
        setupDebugControl(token: token)
        setupTimers()
        engine.refreshSessions()
        Task { await engine.refreshState(); await engine.retryUnsent() }
    }

    // MARK: Panel

    func setupPanel() {
        let size = Self.pillSize
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        // Only the height can be dragged; the width stays fixed so the layout holds.
        p.minSize = NSSize(width: Self.panelWidth, height: 240)
        p.maxSize = NSSize(width: Self.panelWidth, height: 4000)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.title = "Boss"

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let actions = PanelActions(
            toggleExpanded: { [weak self] in self?.toggleExpanded() },
            restartBoss: { [weak self] in self?.restartBoss() },
            openURL: { if let u = URL(string: $0) { NSWorkspace.shared.open(u) } },
            systemAction: { [weak self] in self?.systemAction($0) })
        let host = FirstMouseHostingView(rootView: RootView(engine: engine, actions: actions))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        p.contentView = fx
        panel = p
        // The panel stays out of the way: only the menu-bar dot shows. Clicking the dot opens the full
        // panel. Tests and the film ask for it up front with BOSS_PANEL_EXPANDED=1.
        let showAtLaunch = ProcessInfo.processInfo.environment["BOSS_PANEL_EXPANDED"] == "1"
        engine.panelExpanded = true
        let s = Self.expandedSize
        p.setFrame(NSRect(origin: initialOrigin(size: s), size: s), display: true)
        if showAtLaunch { p.orderFrontRegardless(); engine.panelVisible = true } else { engine.panelVisible = false }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTopRight(); self?.placeChat() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeChat() }
        }
        engine.onChatChange = { [weak self] name in self?.showChat(name) }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine.panelExpanded else { return }
                UserDefaults.standard.set(self.panel.frame.height, forKey: "panelHeight")
                self.saveTopRight()
            }
        }
    }

    func initialOrigin(size: NSSize) -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let d = UserDefaults.standard
        if d.object(forKey: "panelTopRightX") != nil {
            let x = d.double(forKey: "panelTopRightX"), y = d.double(forKey: "panelTopRightY")
            let pt = NSPoint(x: x - size.width, y: y - size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSPoint(x: x - 20, y: y - 20)) }) { return pt }
        }
        return NSPoint(x: vf.maxX - size.width - 14, y: vf.maxY - size.height - 10)
    }

    func saveTopRight() {
        UserDefaults.standard.set(panel.frame.maxX, forKey: "panelTopRightX")
        UserDefaults.standard.set(panel.frame.maxY, forKey: "panelTopRightY")
    }

    func toggleExpanded() { setExpanded(!engine.panelExpanded) }

    func setExpanded(_ e: Bool) {
        engine.panelExpanded = e
        if !e { engine.closeChat() }
        let s = e ? Self.expandedSize : Self.pillSize
        let f = panel.frame
        // keep the top-right corner fixed, stay on screen
        var r = NSRect(x: f.maxX - s.width, y: f.maxY - s.height, width: s.width, height: s.height)
        if let vf = panel.screen?.visibleFrame, r.minY < vf.minY { r.origin.y = vf.minY + 8 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(r, display: true)
        }
    }

    var statusMenu: NSMenu?

    // MARK: - Chat window

    /// Open the chat for `name` beside the panel, or close it (nil).
    func showChat(_ name: String?) {
        guard let name else { chatPanel?.orderOut(nil); return }
        let row = engine.tower.first { $0.name == name }
        chat.open(name: name, shown: row?.nickname ?? name, info: engine.sessionInfo(named: name))
        if chatPanel == nil { chatPanel = makeChatPanel() }
        placeChat()
        chatPanel?.alphaValue = 1
        chatPanel?.orderFrontRegardless()
    }

    func makeChatPanel() -> ChatPanel {
        let p = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: Self.chatWidth, height: 520),
                          styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true   // key only when Roman clicks into the text field
        p.title = "Boss chat"
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        let host = FirstMouseHostingView(rootView: ChatView(model: chat, engine: engine))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        p.contentView = fx
        return p
    }

    /// Same height as the panel, 700 wide, on whichever side of it has room (right first).
    func placeChat() {
        guard let c = chatPanel, engine.chatSession != nil, let p = panel else { return }
        let vf = (p.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        c.setFrame(ChatPlacement.frame(panel: p.frame, screen: vf, width: Self.chatWidth), display: true)
    }

    @objc func statusClicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true, let m = statusMenu {
            statusItem.menu = m
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); engine.panelVisible = false; engine.closeChat() }
        else { panel.orderFrontRegardless(); engine.panelVisible = true }
    }

    // MARK: Status item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        // Click: show or hide the panel. Right-click or control-click: the menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon(force: true)
    }

    func updateStatusIcon(force: Bool = false) {
        let st = engine.status
        guard force || st != lastStatus else { return }
        lastStatus = st
        let stone: NSColor = {
            switch st {
            case .idle: return .systemGray
            case .listening: return .systemBlue
            case .speaking: return .systemGreen
            case .waiting: return .systemOrange
            case .offline: return .systemRed
            }
        }()
        // Mic open: the whole ring goes blue, so "listening" is visible at a glance (Roman's ask).
        statusItem.button?.image = RingLogo.menuBarImage(stone: stone, band: st == .listening ? .systemBlue : nil)
        statusItem.button?.toolTip = "Boss: \(st.rawValue)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ t: String, _ on: Bool? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: t, action: action)
            if let on { i.state = on ? .on : .off }
            return i
        }
        let motto = NSMenuItem(title: "Boss · One voice to rule them all", action: nil, keyEquivalent: "")
        motto.isEnabled = false
        menu.addItem(motto)
        let header = NSMenuItem(title: "\(engine.status.rawValue) · \(engine.countsText)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "Hide panel" : "Show panel") { [weak self] in self?.togglePanel() })
        menu.addItem(item(engine.panelExpanded ? "Collapse panel" : "Expand panel") { [weak self] in self?.toggleExpanded() })
        menu.addItem(item("Mute", engine.muted) { [weak self] in guard let s = self else { return }; s.engine.setMuted(!s.engine.muted) })
        menu.addItem(item("Repeat last") { [weak self] in self?.engine.repeatLast() })
        menu.addItem(.separator())
        menu.addItem(item("Radio sounds", settings.radioSounds) { [weak self] in guard let s = self else { return }; s.settings.radioSounds.toggle() })
        menu.addItem(item("Live target preview", settings.livePreview) { [weak self] in guard let s = self else { return }; s.settings.livePreview.toggle() })
        menu.addItem(item("Telegram when away", settings.telegramFallback) { [weak self] in
            guard let s = self else { return }
            s.settings.telegramFallback.toggle()
            s.engine.deps.telegram?.enabled = s.settings.telegramFallback && s.telegramAllowed
        })
        let lang = NSMenu()
        for (code, title) in [("en", "I speak English"), ("ru", "Я говорю по-русски")] {
            lang.addItem(item(title, settings.languageLock == code) { [weak self] in self?.engine.language = code })
        }
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: ""); langItem.submenu = lang
        menu.addItem(langItem)
        let humor = NSMenu()
        for (n, title) in [(0, "0 · none"), (1, "1 · dry"), (2, "2 · wry"), (3, "3 · cheeky")] {
            humor.addItem(item(title, settings.humor == n) { [weak self] in self?.settings.humor = n })
        }
        let humorItem = NSMenuItem(title: "Humour", action: nil, keyEquivalent: ""); humorItem.submenu = humor
        menu.addItem(humorItem)
        menu.addItem(.separator())
        if !hotkey.isActive {
            menu.addItem(item("Grant Input Monitoring…") { [weak self] in self?.systemAction("grantInputMonitoring") })
            menu.addItem(item("Restart Boss.app") { [weak self] in self?.relaunchApp() })
        }
        menu.addItem(item("Restart Boss") { [weak self] in self?.restartBoss() })
        menu.addItem(item("Quit Boss") { NSApp.terminate(nil) })
    }

    // MARK: Audio, hotkey

    func setupAudio() {
        audio.prepare()
        audio.onPermissionGranted = { [weak self] in self?.engine.removeCard("sys-mic") }
        preview.onPartial = { [weak self] t in self?.engine.updatePartialTranscript(t) }
    }

    let optionSpace = OptionSpaceHotkey()

    func setupHotkey() {
        hotkey.onGesture = { [weak self] events in self?.engine.handleGesture(events) }
        installHotkey(request: true)
        // Office key: Left Option + Space needs no permission at all.
        optionSpace.onDown = { [weak self] in self?.engine.talkControlDown(source: .hotkey) }
        optionSpace.onUp = { [weak self] in self?.engine.talkControlUp(source: .hotkey) }
        optionSpace.onEscape = { [weak self] in self?.engine.cancelTalk() }
        optionSpace.install()
    }

    func installHotkey(request: Bool) {
        let ok = hotkey.install(requestIfNeeded: request)
        engine.hotkeyActive = ok && hotkey.isActive
        if engine.hotkeyActive {
            engine.removeCard("sys-hotkey")
            engine.removeCard("sys-hotkey-relaunch")
        } else if CGPreflightListenEventAccess() {
            // Granted in System Settings after launch: macOS only honours it in a new process.
            relaunchOnceForInputMonitoring()
        } else {
            engine.addSystem("Right Option needs Input Monitoring. Left Option + Space and the Talk button work without it.",
                             level: "warning", action: "grantInputMonitoring", key: "hotkey")
        }
    }

    /// Relaunches the app once (per grant) so a new Input Monitoring permission takes effect.
    func relaunchOnceForInputMonitoring() {
        let key = "relaunchedForInputMonitoringAt"
        let last = UserDefaults.standard.double(forKey: key)
        guard Date().timeIntervalSince1970 - last > 120 else {
            engine.addSystem("Input Monitoring is on, but the hotkey still cannot start. Quit Boss and open it again.",
                             level: "warning", action: "relaunchApp", key: "hotkey-relaunch")
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        relaunchApp()
    }

    /// Newest instance wins: one panel, one hotkey, one mic. Older copies (a relaunch, a launchd
    /// restart, a stray left by an unload) are asked to quit, then forced after 2 s.
    func retireOlderInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        for app in others { app.terminate() }
        if !others.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for app in others where !app.isTerminated { app.forceTerminate() }
            }
        }
    }

    func relaunchApp() {
        // Installed: let launchd restart it, so crash-restart protection stays on.
        let label = "gui/\(getuid())/com.roman.boss.app"
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["print", label]
        check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        if (try? check.run()) != nil { check.waitUntilExit() }
        if check.terminationStatus == 0 {
            let k = Process()
            k.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            k.arguments = ["kickstart", "-k", label]
            if (try? k.run()) != nil { return }
        }
        // Not installed: open a new instance; it retires this one (retireOlderInstances) once it is up.
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in }
    }

    func systemAction(_ a: String) {
        if a == "relaunchApp" { relaunchApp(); return }
        let urls = [
            "grantInputMonitoring": "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "grantMicrophone": "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        if a == "restartBoss" { restartBoss(); return }
        if let u = urls[a].flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
    }

    func restartBoss() {
        if !BossRestarter.restart() {
            engine.addSystem("Could not find boss-up to restart Boss (set BOSS_UP or install bin/boss-up).", level: "error", key: "restart")
        } else {
            engine.addSystem("Restarting Boss…", level: "info", key: "restart")
        }
    }

    // MARK: Channel

    func setupChannel(token: @escaping @Sendable () -> String?) {
        let url = URL(string: "http://127.0.0.1:\(Ports.channel())/events")!
        let client = SSEClient(source: URLSessionSSESource(url: url, token: token))
        client.onMessage = { [weak self] m in
            Task { @MainActor in self?.engine.handleSSE(m) }
        }
        client.onStatus = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                if case .open = st { await self.pollHealth() }
                if case .closed = st { await self.pollHealth() }
            }
        }
        client.start()
        sse = client
    }

    func pollHealth() async {
        let h = await engine.deps.channel.health()
        engine.applyHealth(h)
    }

    func setupDebugControl(token: @escaping @Sendable () -> String?) {
        let env = ProcessInfo.processInfo.environment
        guard env["BOSS_DEBUG_CONTROL"] == "1" || settings.debugControl else { return }
        engine.allowSilentAnswerWindow = true
        engine.snapshotter = { [weak self] path, window in
            guard let view = (window == "chat" ? self?.chatPanel?.contentView : self?.panel.contentView) else { return false }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: URL(fileURLWithPath: path))) != nil
        }
        let server = DebugServer(router: DebugControlRouter(token: token, handler: engine))
        do { try server.start() } catch { NSLog("Boss: debug control could not start: \(error)") }
        debugServer = server
    }

    // MARK: Timers

    func setupTimers() {
        func every(_ s: TimeInterval, _ f: @escaping @MainActor () -> Void) {
            let t = Timer(timeInterval: s, repeats: true) { _ in MainActor.assumeIsolated { f() } }
            RunLoop.main.add(t, forMode: .common)
            timers.append(t)
        }
        every(0.05) { [weak self] in
            guard let self else { return }
            let rec = self.engine.recording != nil
            if rec { self.engine.updateLevel(self.audio.level) }
            if rec != self.wasRecording {
                self.wasRecording = rec
                self.optionSpace.setEscapeActive(rec)
                if rec, self.settings.livePreview {
                    self.preview.ensureAuthorization()
                    self.audio.pipe.onRecordingBuffer = self.preview.begin()
                } else if !rec {
                    self.audio.pipe.onRecordingBuffer = nil
                    self.preview.stop()
                }
            }
            self.updateStatusIcon()
        }
        every(1) { [weak self] in
            guard let self else { return }
            Task { await self.engine.retryTick(now: CACurrentMediaTime()) }
        }
        every(2) { [weak self] in
            guard let self else { return }
            self.engine.refreshSessions()
            if self.engine.chatSession != nil, self.chatPanel?.isVisible == true {
                self.chat.status = self.engine.sessionInfo(named: self.chat.name)?.status ?? self.chat.status
                self.chat.reload()
            }
        }
        // Out of the way unless in use: 92% transparent when the mouse is over neither the panel nor
        // the chat, fully visible while hovered, while Roman types in the chat, while he talks, or
        // while a question waits for him. Both windows follow the same rule together.
        every(0.2) { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            let mouse = NSEvent.mouseLocation
            let chat = self.chatPanel.flatMap { $0.isVisible ? $0 : nil }
            let focused = p.frame.insetBy(dx: -6, dy: -6).contains(mouse)
                || (chat.map { $0.frame.insetBy(dx: -6, dy: -6).contains(mouse) || $0.isKeyWindow } ?? false)
                || self.engine.recording != nil || self.engine.status == .waiting
            let target: CGFloat = focused ? 1.0 : 0.08   // 92% transparent when not in use
            for w in [p, chat].compactMap({ $0 }) where abs(w.alphaValue - target) > 0.01 {
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; w.animator().alphaValue = target }
            }
        }
        every(5) { [weak self] in
            guard let self else { return }
            Task { await self.pollHealth(); await self.engine.refreshState() }
            if !self.engine.hotkeyActive { self.installHotkey(request: false) }
            self.engine.deps.telegram?.enabled = self.settings.telegramFallback && self.telegramAllowed
        }
        Task { await pollHealth() }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void
    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { closure() }
}
