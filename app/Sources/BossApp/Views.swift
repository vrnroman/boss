import SwiftUI
import AppKit
import BossCore

// MARK: - Palette

enum Palette {
    static let idle = Color(white: 0.62)
    static let listening = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let speaking = Color(red: 0.25, green: 0.82, blue: 0.48)
    static let waiting = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let offline = Color(red: 1.0, green: 0.38, blue: 0.32)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)

    static func status(_ s: AppStatus) -> Color {
        switch s {
        case .idle: return idle
        case .listening: return listening
        case .speaking: return speaking
        case .waiting: return waiting
        case .offline: return offline
        }
    }
}

/// UI-side actions the engine can't do itself.
@MainActor
struct PanelActions {
    var toggleExpanded: () -> Void
    var restartBoss: () -> Void
    var openURL: (String) -> Void
    var systemAction: (String) -> Void
}

// MARK: - Root

struct RootView: View {
    @Bindable var engine: BossEngine
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 0) {
            PillView(engine: engine, actions: actions)
            if engine.panelExpanded {
                Divider().overlay(Color.white.opacity(0.08))
                ExpandedView(engine: engine, actions: actions)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.78),
                                    Color(red: 0.04, green: 0.05, blue: 0.07).opacity(0.86)],
                           startPoint: .top, endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: engine.panelExpanded)
    }
}

// MARK: - Pill

struct StateDot: View {
    let status: AppStatus
    @State private var pulse = false
    var body: some View {
        let c = Palette.status(status)
        ZStack {
            Circle().fill(c.opacity(0.25)).frame(width: 18, height: 18)
                .scaleEffect(pulse && (status == .listening || status == .speaking) ? 1.35 : 1)
                .opacity(status == .listening || status == .speaking ? 1 : 0.0)
            Circle().fill(c).frame(width: 10, height: 10)
                .shadow(color: c.opacity(0.8), radius: 4)
        }
        .frame(width: 20, height: 20)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct LevelMeter: View {
    let level: Double
    var bars = 12
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let on = Double(i) / Double(bars) < level
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? Palette.listening : Color.white.opacity(0.12))
                    .frame(width: 3, height: 4 + CGFloat(i % 4) * 2 + (on ? 4 : 0))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: level)
    }
}

struct Chip: View {
    let text: String
    var color: Color = Palette.secondary
    var filled = false
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(filled ? Color.black.opacity(0.85) : color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
    }
}

struct PillView: View {
    let engine: BossEngine
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 10) {
            StateDot(status: engine.status)
            VStack(alignment: .leading, spacing: 2) {
                primaryLine
                secondaryLine
            }
            Spacer(minLength: 4)
            if engine.status == .offline {
                HStack(spacing: 6) {
                    Chip(text: "offline", color: Palette.offline)
                        .help(engine.channelReachable ? "Boss is offline" : "The channel is down")
                    Button(action: actions.restartBoss) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Restart Boss")
                    .buttonStyle(SmallButtonStyle(tint: Palette.offline))
                }
            }
            Button(action: actions.toggleExpanded) {
                Image(systemName: engine.panelExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(engine.panelExpanded ? "Collapse" : "Expand")
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .contentShape(Rectangle())
    }

    @ViewBuilder var primaryLine: some View {
        if let r = engine.recording {
            HStack(spacing: 8) {
                Text(r.questionID != nil ? "Answering…" : "Listening")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.listening)
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    Text(timer(ctx.date.timeIntervalSince(r.startedAt)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
                LevelMeter(level: engine.level)
                if let t = engine.previewTarget { Chip(text: "→ \(t)", color: Palette.listening, filled: true) }
            }
        } else {
            HStack(spacing: 6) {
                Text(engine.lastRouteText ?? "Boss")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if engine.muted {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }
            }
        }
    }

    var secondaryLine: some View {
        HStack(spacing: 6) {
            Text(engine.recording != nil ? "release to send · esc to cancel" : engine.countsText)
                .foregroundStyle(engine.tower.contains { $0.group == .waiting } && engine.recording == nil ? Palette.waiting : Palette.secondary)
            if engine.recording == nil, let b = engine.blindText {
                Text("·").foregroundStyle(Palette.tertiary)
                Text(b).foregroundStyle(Palette.tertiary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    func timer(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @Bindable var engine: BossEngine
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ControlsRow(engine: engine)
            SectionHeader(title: "Sessions", trailing: engine.tower.isEmpty ? nil : "\(engine.tower.count)")
            TowerView(engine: engine)
            SectionHeader(title: "Feed", trailing: nil)
            FeedView(engine: engine, actions: actions)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct SectionHeader: View {
    let title: String
    let trailing: String?
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.8).foregroundStyle(Palette.tertiary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.tertiary) }
        }
        .padding(.horizontal, 4)
    }
}

struct ControlsRow: View {
    let engine: BossEngine
    @State private var down = false

    var body: some View {
        let live = engine.recording != nil
        HStack(spacing: 6) {
            // Talk: hold and release to send, or click once to start and click again to send.
            HStack(spacing: 8) {
                Image(systemName: live ? "waveform" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: live)
                Text(engine.talkLatched ? "Click to send" : live ? "Release to send" : "Talk")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(live ? Palette.listening : Color.white.opacity(0.10))
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(live ? 0.0 : 0.10)))
            .scaleEffect(down ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: down)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down { down = true; engine.talkControlDown(source: .button) }
                    }
                    .onEnded { _ in
                        down = false
                        engine.talkControlUp(source: .button)
                    }
            )
            .help("Click to start and click to send, or hold and release. Keys: hold Right Option, or Left Option + Space")

            LanguageToggle(engine: engine)
            IconButton(symbol: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       active: engine.muted, help: engine.muted ? "Unmute" : "Mute") { engine.setMuted(!engine.muted) }
            IconButton(symbol: "text.bubble", active: false, help: "Say the last answer again") { engine.repeatLast() }
        }
    }
}

/// EN | RU: the language Roman will speak. Whisper is told it; nothing is auto-detected.
struct LanguageToggle: View {
    @Bindable var engine: BossEngine
    var body: some View {
        HStack(spacing: 0) {
            ForEach(["en", "ru"], id: \.self) { code in
                Button { engine.language = code } label: {
                    Text(code.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(engine.language == code ? .black : .white.opacity(0.7))
                        .frame(width: 24, height: 30)
                        .background(engine.language == code ? Color.white.opacity(0.85) : Color.clear)
                }
                .buttonStyle(.plain)
                .help(code == "en" ? "I speak English" : "Я говорю по-русски")
            }
        }
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct IconButton: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Palette.waiting : .white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(hover ? 0.14 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct SmallButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.28 : 0.15)))
    }
}

// MARK: - Timing tower

struct TowerView: View {
    let engine: BossEngine
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 0) {
            if engine.tower.isEmpty {
                Text("No live sessions").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            ForEach(Array(engine.tower.enumerated()), id: \.element.id) { i, row in
                TowerRowView(pos: i + 1, row: row) { engine.showSession(row.name) }
            }
        }
        .padding(4)
        }
        .frame(maxHeight: min(CGFloat(max(engine.tower.count, 1)) * 30 + 8, 196))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.cardStroke))
    }
}

struct TowerRowView: View {
    let pos: Int
    let row: TowerRow
    let show: () -> Void
    @State private var hover = false

    var color: Color {
        switch row.group {
        case .waiting: return Palette.waiting
        case .busy: return Palette.speaking
        case .idle, .other: return Palette.idle
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(pos)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Palette.tertiary).frame(width: 12)
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: row.detail == nil ? 16 : 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.nickname ?? row.name).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(row.group == .idle ? .white.opacity(0.55) : .white.opacity(0.95))
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    if row.nickname != nil {
                        Text(row.name).font(.system(size: 10)).foregroundStyle(Palette.tertiary).lineLimit(1)
                    } else if row.cwdBase != row.name {
                        Text(row.cwdBase).font(.system(size: 10)).foregroundStyle(Palette.tertiary).lineLimit(1)
                    }
                }
                if let d = row.detail {
                    Text(d).font(.system(size: 11)).foregroundStyle(row.group == .waiting ? Palette.waiting.opacity(0.9) : Palette.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let w = row.waitText {
                    Text(w).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.waiting)
                } else {
                    Text(row.group == .busy ? "working" : row.status).font(.system(size: 10, weight: .medium)).foregroundStyle(color.opacity(0.9))
                }
                if let t = row.trust {
                    Text(t).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(row.graduated ? Palette.speaking.opacity(0.8) : Palette.tertiary)
                        .help("routed blind \(t)")
                }
            }
            Button(action: show) {
                Image(systemName: "macwindow").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            .buttonStyle(.plain).opacity(hover ? 1 : 0.45).help("Show session")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.05 : 0)))
        .onHover { hover = $0 }
    }
}

// MARK: - Feed

struct FeedView: View {
    let engine: BossEngine
    let actions: PanelActions
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 8) {
                if engine.feed.cards.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "waveform").font(.system(size: 20)).foregroundStyle(Palette.tertiary)
                        Text("Hold Right Option and speak").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                ForEach(engine.feed.cards) { card in
                    CardView(card: card, engine: engine, actions: actions)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: engine.feed.cards.map(\.id))
        }
        .frame(maxHeight: .infinity)
    }
}

struct CardView: View {
    let card: Card
    let engine: BossEngine
    let actions: PanelActions

    var accent: Color {
        switch card.kind {
        case .youSaid: return Palette.listening
        case .report: return Palette.speaking
        case .question: return Palette.waiting
        case .confirm: return Palette.listening
        case .system: return card.level == "error" ? Palette.offline : card.level == "info" ? Palette.idle : Palette.waiting
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            content
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(accent.opacity(0.9)).frame(width: 3).padding(.vertical, 7)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(card.kind == .question && card.answered != true ? Palette.waiting.opacity(0.45) : Palette.cardStroke))
    }

    var title: (String, String) {
        switch card.kind {
        case .youSaid: return ("You said", "person.wave.2.fill")
        case .report: return (card.session ?? "Boss", card.note == "report" || card.note == nil ? "checkmark.bubble.fill" : "info.bubble.fill")
        case .question: return (card.session.map { "\($0) asks" } ?? "Boss asks", "questionmark.bubble.fill")
        case .confirm: return ("Routing", "arrow.triangle.branch")
        case .system: return ("System", card.level == "error" ? "exclamationmark.octagon.fill" : card.level == "info" ? "info.circle.fill" : "exclamationmark.triangle.fill")
        }
    }

    var header: some View {
        HStack(spacing: 6) {
            Image(systemName: title.1).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            Text(title.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
            if let l = card.langChip, card.kind == .youSaid { Chip(text: l) }
            if card.kind == .youSaid, let t = card.target { Chip(text: "→ \(engine.shownName(t))", color: Palette.listening) }
            Spacer()
            if card.kind == .youSaid, let s = card.status { StatusChip(status: s) }
            Text(SGT.time(card.createdAt).replacingOccurrences(of: " SGT", with: ""))
                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Palette.tertiary)
                .help(SGT.time(card.createdAt))
        }
        .padding(.leading, 4)
    }

    @ViewBuilder var content: some View {
        Group {
            switch card.kind {
            case .youSaid: youSaid
            case .report: report
            case .question: question
            case .confirm: ConfirmContent(card: card, engine: engine)
            case .system: system
            }
        }
        .padding(.leading, 4)
    }

    var bodyText: some View {
        Text(card.text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    @ViewBuilder var youSaid: some View {
        bodyText
        if let n = card.note, ["failed", "queued", "dropped"].contains(card.status ?? "") {
            Text(n).font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
        }
        HStack(spacing: 6) {
            if let uid = card.utteranceID {
                if ["sent", "delivered", "asking"].contains(card.status ?? "") {
                    Button("Undo") { Task { await engine.undo(utteranceID: uid) } }.buttonStyle(SmallButtonStyle())
                }
                if ["failed", "queued", "sent", "delivered", "ignored"].contains(card.status ?? "") {
                    Button("Resend") { Task { await engine.resend(utteranceID: uid) } }.buttonStyle(SmallButtonStyle())
                }
            }
        }
    }

    @ViewBuilder var report: some View {
        bodyText
        HStack(spacing: 6) {
            ForEach(card.links, id: \.self) { l in
                Button { actions.openURL(l.url) } label: { Label(l.title, systemImage: "link") }
                    .buttonStyle(SmallButtonStyle(tint: Palette.speaking))
            }
            if let s = card.session, s != "boss" {
                Button { engine.showSession(s) } label: { Label("Show session", systemImage: "macwindow") }
                    .buttonStyle(SmallButtonStyle())
            }
        }
    }

    @ViewBuilder var question: some View {
        bodyText
        if card.answered == true {
            Label(card.answer ?? "answered", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.speaking)
        } else {
            if engine.answerWindow?.questionID == card.questionID {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(Palette.listening)
                    Text("Listening for your answer…").font(.system(size: 10.5)).foregroundStyle(Palette.listening)
                }
            }
            FlowChoices(choices: card.choices) { c in
                if let q = card.questionID { Task { _ = await engine.tapChoice(questionID: q, choice: c) } }
            }
        }
    }

    @ViewBuilder var system: some View {
        bodyText
        if let a = card.action {
            Button(actionTitle(a)) { actions.systemAction(a) }.buttonStyle(SmallButtonStyle(tint: accent))
        }
    }

    func actionTitle(_ a: String) -> String {
        switch a {
        case "grantInputMonitoring": return "Open Input Monitoring"
        case "grantMicrophone": return "Open Microphone settings"
        case "restartBoss": return "Restart Boss"
        case "relaunchApp": return "Restart Boss.app"
        default: return a
        }
    }
}

struct StatusChip: View {
    let status: String
    var color: Color {
        switch status {
        case "delivered": return Palette.speaking
        case "sent": return Palette.speaking.opacity(0.8)
        case "failed": return Palette.offline
        case "queued", "asking": return Palette.waiting
        case "undone", "ignored", "dropped": return Palette.idle
        default: return Palette.listening
        }
    }
    var label: String { status == "transcribing" ? "transcribing…" : status }
    var body: some View { Chip(text: label, color: color) }
}

struct FlowChoices: View {
    let choices: [String]
    let tap: (String) -> Void
    var body: some View {
        // A real flow layout: buttons keep their names on one line and wrap to the next row as a whole.
        WrapLayout(spacing: 6) {
            ForEach(choices, id: \.self) { c in
                Button { tap(c) } label: { Text(c).lineLimit(1).fixedSize() }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(ChoiceButtonStyle())
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

struct ChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.waiting.opacity(configuration.isPressed ? 0.7 : 0.95)))
    }
}

struct ConfirmContent: View {
    let card: Card
    let engine: BossEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("→ \(card.target.map(engine.shownName) ?? "?")").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if let r = card.reason, !r.isEmpty { Text("(\(r))").font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1) }
            }
            if card.cancelled == true {
                Text("Cancelled").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.offline)
            } else if let deadline = card.deadline {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let total = Double(card.windowMs ?? 2500) / 1000
                    let left = max(0, deadline.timeIntervalSince(ctx.date))
                    HStack(spacing: 8) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.1))
                                Capsule().fill(Palette.listening).frame(width: g.size.width * (left / total))
                            }
                        }
                        .frame(height: 4)
                        if left > 0 {
                            Button("Cancel") { if let r = card.routeID { Task { await engine.cancelRoute(routeID: r) } } }
                                .buttonStyle(SmallButtonStyle(tint: Palette.offline))
                        } else {
                            Text("sent").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.speaking)
                        }
                    }
                }
            }
        }
    }
}
