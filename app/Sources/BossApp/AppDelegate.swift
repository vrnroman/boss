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
    var panel: FloatingPanel!
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

    static let pillSize = NSSize(width: 360, height: 56)
    static let expandedSize = NSSize(width: 380, height: 640)

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: paths.outbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let paths = self.paths
        let token: @Sendable () -> String? = { paths.readToken() }
        speech = SpeechOut(settings: settings)
        let channel = ChannelClient(token: token)
        let store = SessionsStore.fromEnvironment()
        let telegram = TelegramFallback(away: AwayDetector(idleSeconds: {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }), runner: TelegramFallback.shellRunner())
        telegram.enabled = settings.telegramFallback

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
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
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
        if ProcessInfo.processInfo.environment["BOSS_PANEL_EXPANDED"] == "1" { engine.panelExpanded = true }
        let s = engine.panelExpanded ? Self.expandedSize : Self.pillSize
        p.setFrame(NSRect(origin: initialOrigin(size: s), size: s), display: true)
        p.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTopRight() }
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

    func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); engine.panelVisible = false }
        else { panel.orderFrontRegardless(); engine.panelVisible = true }
    }

    // MARK: Status item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon(force: true)
    }

    func updateStatusIcon(force: Bool = false) {
        let st = engine.status
        guard force || st != lastStatus else { return }
        lastStatus = st
        let (symbol, color): (String, NSColor) = {
            switch st {
            case .idle: return ("waveform.circle.fill", .secondaryLabelColor)
            case .listening: return ("waveform.circle.fill", .systemBlue)
            case .speaking: return ("waveform.circle.fill", .systemGreen)
            case .waiting: return ("questionmark.circle.fill", .systemOrange)
            case .offline: return ("exclamationmark.triangle.fill", .systemYellow)
            }
        }()
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [color]))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Boss \(st.rawValue)")?.withSymbolConfiguration(cfg)
        img?.isTemplate = (st == .idle)
        statusItem.button?.image = img
        statusItem.button?.toolTip = "Boss: \(st.rawValue)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ t: String, _ on: Bool? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: t, action: action)
            if let on { i.state = on ? .on : .off }
            return i
        }
        let header = NSMenuItem(title: "Boss · \(engine.status.rawValue) · \(engine.countsText)", action: nil, keyEquivalent: "")
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
            s.engine.deps.telegram?.enabled = s.settings.telegramFallback
        })
        let lang = NSMenu()
        for (code, title) in [("auto", "Auto (English / Russian)"), ("en", "English"), ("ru", "Русский")] {
            lang.addItem(item(title, settings.languageLock == code) { [weak self] in self?.settings.languageLock = code })
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

    func setupHotkey() {
        hotkey.onGesture = { [weak self] events in self?.engine.handleGesture(events) }
        installHotkey(request: true)
    }

    func installHotkey(request: Bool) {
        let ok = hotkey.install(requestIfNeeded: request)
        engine.hotkeyActive = ok && hotkey.isActive
        if engine.hotkeyActive {
            engine.removeCard("sys-hotkey")
        } else {
            engine.addSystem("Grant Input Monitoring for the Right Option hotkey. The Talk button works meanwhile.",
                             level: "warning", action: "grantInputMonitoring", key: "hotkey")
        }
    }

    func systemAction(_ a: String) {
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
        every(2) { [weak self] in self?.engine.refreshSessions() }
        every(5) { [weak self] in
            guard let self else { return }
            Task { await self.pollHealth(); await self.engine.refreshState() }
            if !self.engine.hotkeyActive { self.installHotkey(request: false) }
            self.engine.deps.telegram?.enabled = self.settings.telegramFallback
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
