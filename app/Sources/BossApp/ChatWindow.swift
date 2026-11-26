import AppKit
import SwiftUI
import BossCore

/// The chat window beside the panel: a normal window, a child of the panel, so the two come
/// forward and go behind other apps together.
final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One session as Roman wants it: a short status and plan, and every ask with its own answer.
@MainActor
@Observable
final class ChatModel {
    var name = ""          // the session's real name (routing, lookups)
    var shown = ""         // what Roman sees and says (nickname or name)
    var folder = ""
    var status = ""
    var thread = SessionThread(asks: [], key: "")
    var digest: SessionDigest?
    var summarizing = false
    var draft = ""
    var sending = false
    var note: String?
    var missing = false
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var stamp: (Date, UInt64)?
    @ObservationIgnored let keeper: DigestKeeper

    init(keeper: DigestKeeper) {
        self.keeper = keeper
        keeper.onChange = { [weak self] in self?.pull() }
    }

    var working: Bool { !(status == "idle" || status.isEmpty) }
    var cards: [AskCard] { DigestView.cards(thread, digest: digest, working: working) }

    func open(name: String, shown: String, info: SessionInfo?) {
        if self.name != name { thread = SessionThread(asks: [], key: ""); draft = ""; note = nil; stamp = nil }
        self.name = name; self.shown = shown
        folder = info.map { ($0.cwd as NSString).lastPathComponent } ?? ""
        status = info?.status ?? ""
        if let i = info, !i.sessionId.isEmpty {
            url = SessionChat.transcriptURL(home: FileManager.default.homeDirectoryForCurrentUser, cwd: i.cwd, sessionId: i.sessionId)
            keeper.select(sessionId: i.sessionId)
        } else { url = nil; keeper.select(sessionId: "") }
        pull()
        reload()
    }

    /// Re-read the transcript only when it changed (size or time); ask for a new digest when due.
    func reload() {
        guard let url, let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let size = (a[.size] as? NSNumber)?.uint64Value else {
            missing = true; thread = SessionThread(asks: [], key: ""); return
        }
        missing = false
        if stamp == nil || stamp!.0 != m || stamp!.1 != size {
            stamp = (m, size)
            let t = SessionThread.load(url: url)
            if t != thread { thread = t }
        }
        keeper.update(thread, status: status)
        pull()
    }

    private func pull() {
        if digest != keeper.digest { digest = keeper.digest }
        if summarizing != keeper.running { summarizing = keeper.running }
    }
}

struct ChatView: View {
    @Bindable var model: ChatModel
    let engine: BossEngine
    @FocusState private var typing: Bool
    @State private var expanded: Set<String> = []

    var statusColor: Color {
        switch model.status {
        case "idle", "": return Palette.idle
        case "waiting", "waiting_input": return Palette.waiting
        default: return Palette.speaking   // busy, shell (a command running): working
        }
    }

    var statusText: String {
        switch model.status {
        case "idle", "": return "idle"
        case "waiting", "waiting_input": return "waiting for you"
        default: return "working"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            statusCard.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            content
            Divider().overlay(Color.white.opacity(0.08))
            input
        }
        .environment(\.colorScheme, .dark)
    }

    var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(model.shown).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
            if !model.folder.isEmpty && model.folder != model.shown {
                Text(model.folder).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
            Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor.opacity(0.9))
            Spacer()
            Button { engine.showSession(model.name) } label: {
                Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).help("Open the session's terminal for everything")
            Button { engine.closeChat() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).help("Close")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var content: some View {
        let cards = model.cards
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.missing {
                        Text("No transcript found for this session yet.").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    } else if cards.isEmpty {
                        Text("Nothing asked yet. Your questions and their answers show up here, one card each.")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    } else {
                        asksHeader(cards)
                        ForEach(cards) { c in AskCardView(card: c, expanded: expanded.contains(c.id),
                                                          toggle: { toggle(c.id) }, askAgain: { askAgain(c) }).id(c.id) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: cards.last?.id) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.name) { _, _ in expanded = []; DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    @ViewBuilder var statusCard: some View {
        let d = model.digest
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("STATUS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.tertiary)
                if model.summarizing { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                Spacer()
            }
            if let d, !d.headline.isEmpty {
                Text(d.headline).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                if !d.done.isEmpty || !d.next.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(d.done.suffix(3).enumerated()), id: \.offset) { _, s in planLine("checkmark.circle.fill", Palette.speaking, s, dim: true) }
                        ForEach(Array(d.next.prefix(3).enumerated()), id: \.offset) { _, s in planLine("circle", Palette.waiting, s, dim: false) }
                    }
                }
            } else {
                Text(model.working ? "Working on: \(model.thread.asks.last.map { DigestView.clip($0.text, 90) } ?? "…")"
                                   : (model.summarizing ? "Summarizing…" : statusText.capitalized))
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: 210, alignment: .top)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.07)))
    }

    func planLine(_ icon: String, _ color: Color, _ text: String, dim: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color.opacity(0.9))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(dim ? 0.62 : 0.88))
        }
    }

    func asksHeader(_ cards: [AskCard]) -> some View {
        let open = cards.filter { $0.state == .working }.count
        let missed = cards.filter { $0.state == .missed }.count
        return HStack(spacing: 8) {
            Text("YOUR ASKS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.tertiary)
            if open > 0 { Text("\(open) in progress").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.listening) }
            if missed > 0 { Text("\(missed) not answered").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.waiting) }
            Spacer()
        }.padding(.top, 2)
    }

    func toggle(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }

    func askAgain(_ c: AskCard) {
        model.draft = "You didn't answer this yet: \"\(c.question)\". Please answer it."
        send()
    }

    var input: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(model.shown)…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...5)
                    .focused($typing)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: model.sending ? "ellipsis.circle" : "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundStyle(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Palette.tertiary : Palette.listening)
                }
                .buttonStyle(.plain).disabled(model.sending).help("Send through Boss")
            }
            if let n = model.note { Text(n).font(.system(size: 10)).foregroundStyle(Palette.tertiary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    func send() {
        let text = model.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.sending else { return }
        model.sending = true
        model.note = "Sending through Boss…"
        let shown = model.shown
        Task { @MainActor in
            let item = await engine.sendTyped(to: shown, text: text)
            model.sending = false
            model.draft = ""
            model.note = item?.state == .sent ? "Sent. It shows up here once \(shown) has it."
                                              : "Not sent yet (\(item?.error ?? "unknown")); Boss keeps retrying."
        }
    }
}

/// One ask: what Roman said (small), the answer (prominent), its state; the full reply on demand.
struct AskCardView: View {
    let card: AskCard
    let expanded: Bool
    let toggle: () -> Void
    let askAgain: () -> Void

    var badge: (String, Color) {
        switch card.state {
        case .answered: return (card.isQuestion ? "Answered" : "Done", Palette.speaking)
        case .working: return ("Working…", Palette.listening)
        case .missed: return ("Not answered", Palette.waiting)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: card.via == .voice ? "mic.fill" : "keyboard").font(.system(size: 9.5)).foregroundStyle(Palette.tertiary)
                Text(card.question).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                Spacer(minLength: 8)
                if let at = card.at { Text(SGT.smart(at, now: Date())).font(.system(size: 10)).foregroundStyle(Palette.tertiary).fixedSize() }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(badge.0).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(badge.1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(badge.1.opacity(0.14))).fixedSize()
                if !card.answer.isEmpty {
                    Text(card.answer).font(.system(size: 13)).foregroundStyle(.white.opacity(0.93))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if card.state == .missed {
                    Text("The session moved on without answering this.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            if expanded, let full = card.full {
                Text(ChatBubble.markdown(full)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
            }
            HStack(spacing: 14) {
                if card.full != nil {
                    Button(expanded ? "Hide reply" : "Full reply", action: toggle).buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.secondary)
                }
                if card.state == .missed {
                    Button("Ask again", action: askAgain).buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.waiting)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(card.state == .missed ? Palette.waiting.opacity(0.07) : Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(card.state == .missed ? Palette.waiting.opacity(0.35) : Color.white.opacity(0.07)))
    }
}

struct ChatBubble: View {
    let entry: ChatEntry

    var label: (String, Color) {
        switch entry.kind {
        case .typed: return ("You", Palette.listening)
        case .voice: return ("You · via Boss", Palette.listening)
        case .result: return ("Result", Palette.speaking)
        case .answer: return ("Answer", Palette.speaking)
        case .question: return ("Question for you", Palette.waiting)
        }
    }

    var body: some View {
        let mine = entry.role == .you
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(label.1.opacity(0.9))
                if let at = entry.at { Text(SGT.smart(at, now: Date())).font(.system(size: 10)).foregroundStyle(Palette.tertiary) }
            }
            Text(Self.markdown(entry.text))
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(mine ? 0.9 : 0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(mine ? Palette.listening.opacity(0.16) : (entry.kind == .question ? Palette.waiting.opacity(0.10) : Color.white.opacity(0.06))))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(entry.kind == .question ? Palette.waiting.opacity(0.35) : Color.white.opacity(0.06)))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 60)
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
