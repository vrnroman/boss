import SwiftUI
import BossCore

/// Subscription limits at the foot of the panel. Closed: one quiet line, the fullest window of each
/// provider. Open: every window with its reset. Hidden entirely when no subscription is found.
struct LimitsBar: View {
    @Bindable var store: LimitsStore
    var onOpen: () -> Void = {}
    @State private var hover = false

    var body: some View {
        if !store.providers.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = ctx.date
                VStack(alignment: .leading, spacing: 0) {
                    summary(now: now)
                    if store.expanded {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(store.providers) { p in ProviderBlock(p: p, now: now) }
                        }
                        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card.opacity(store.expanded ? 1 : 0.6)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.cardStroke))
                .animation(.easeInOut(duration: 0.18), value: store.expanded)
            }
        }
    }

    func summary(now: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            ForEach(store.providers) { p in
                let used = p.limitedNow ? 1 : (p.windows.map { LimitsStore.current($0, now: now).used }.max() ?? 0)
                HStack(spacing: 4) {
                    Text(p.name).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                    Text(p.limitedNow ? "limited" : pct(used))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(levelColor(used))
                }
                .help(tooltip(p, now: now))
            }
            Spacer(minLength: 0)
            Image(systemName: store.expanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.tertiary.opacity(hover ? 1.6 : 1))
        }
        .padding(.horizontal, 9).frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture {
            store.expanded.toggle()
            if store.expanded { onOpen() }
        }
        .onHover { hover = $0 }
        .help(store.expanded ? "Hide limits" : "Show limits and when they reset")
    }

    func tooltip(_ p: ProviderLimits, now: Date) -> String {
        p.windows.map { w in
            let c = LimitsStore.current(w, now: now)
            let r = ResetText.format(c.resetsAt, now: now)
            return "\(w.label) \(pct(c.used))" + (r.isEmpty ? "" : ", resets \(r)")
        }.joined(separator: " · ")
    }
}

struct ProviderBlock: View {
    let p: ProviderLimits
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(p.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                if let n = p.note {
                    Text(n).font(.system(size: 10, weight: .medium)).foregroundStyle(p.limitedNow ? Palette.offline : Palette.waiting)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if LimitsStore.isStale(p, now: now) {
                    Text("as of \(clock(p.asOf))").font(.system(size: 9)).foregroundStyle(Palette.tertiary)
                }
            }
            ForEach(Array(p.windows.enumerated()), id: \.offset) { _, w in
                let c = LimitsStore.current(w, now: now)
                HStack(spacing: 8) {
                    Text(w.label).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        .frame(width: 78, alignment: .leading).lineLimit(1).truncationMode(.tail)
                    UsageBar(used: c.used).frame(width: 110, height: 4)
                    Text(pct(c.used)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(levelColor(c.used)).frame(width: 34, alignment: .trailing)
                    Spacer(minLength: 0)
                    if c.resetsAt != nil {
                        Text("resets \(ResetText.format(c.resetsAt, now: now))")
                            .font(.system(size: 10)).foregroundStyle(Palette.tertiary).lineLimit(1)
                            .help(ResetText.countdown(c.resetsAt, now: now))
                    }
                }
            }
        }
    }

    func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

struct UsageBar: View {
    let used: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(levelColor(used)).frame(width: max(used > 0 ? 3 : 0, g.size.width * used))
            }
        }
    }
}

func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

func levelColor(_ used: Double) -> Color {
    switch LimitsStore.level(used) {
    case .ok: return Palette.speaking.opacity(0.85)
    case .warn: return Palette.waiting
    case .high: return Palette.offline
    }
}
