import AppKit
import SwiftUI
import BossCore

/// The chat window beside the panel: a normal window, a child of the panel, so the two come
/// forward and go behind other apps together.
final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One session's recent chat, re-read from its transcript when the file changes.
@MainActor
@Observable
final class ChatModel {
    var name = ""          // the session's real name (routing, lookups)
    var shown = ""         // what Roman sees and says (nickname or name)
    var folder = ""
    var status = ""
    var entries: [ChatEntry] = []
    var draft = ""
    var sending = false
    var note: String?
    var missing = false
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var stamp: (Date, UInt64)?

    func open(name: String, shown: String, info: SessionInfo?) {
        if self.name != name { entries = []; draft = ""; note = nil; stamp = nil }
        self.name = name; self.shown = shown
        folder = info.map { ($0.cwd as NSString).lastPathComponent } ?? ""
        status = info?.status ?? ""
        if let i = info, !i.sessionId.isEmpty {
            url = SessionChat.transcriptURL(home: FileManager.default.homeDirectoryForCurrentUser, cwd: i.cwd, sessionId: i.sessionId)
        } else { url = nil }
        reload()
    }

    /// Re-read only when the transcript changed (size or time).
    func reload() {
        guard let url, let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let size = (a[.size] as? NSNumber)?.uint64Value else {
            missing = true; entries = []; return
        }
        missing = false
        if let s = stamp, s.0 == m, s.1 == size { return }
        stamp = (m, size)
        entries = SessionChat.load(url: url)
    }
}

struct ChatView: View {
    @Bindable var model: ChatModel
    let engine: BossEngine
    @FocusState private var typing: Bool

    var statusColor: Color {
        switch model.status {
        case "idle", "": return Palette.idle
        case "waiting", "waiting_input": return Palette.waiting
        default: return Palette.speaking   // busy, shell (a command running): working
        }
    }

    var statusText: String {
        switch model.status {
        case "idle", "": return model.status
        case "waiting", "waiting_input": return "waiting for you"
        default: return "working"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            messages
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
            }.buttonStyle(.plain).help("Show the session's terminal")
            Button { engine.closeChat() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain).help("Close")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var messages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {   // at most 40 entries: a plain stack scrolls exactly to the bottom
                    if model.missing {
                        Text("No transcript found for this session yet.").font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.top, 8)
                    } else if model.entries.isEmpty {
                        Text("Nothing finished yet: results, answers and questions show up here.")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.top, 8)
                    }
                    ForEach(model.entries) { e in ChatBubble(entry: e).id(e.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.entries.last?.id) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.name) { _, _ in DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
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
            if item?.state == .sent {
                model.draft = ""
                model.note = "Sent. It shows up here once \(shown) has it."
            } else {
                model.note = "Not sent yet (\(item?.error ?? "unknown")); Boss keeps retrying."
                model.draft = ""
            }
        }
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
