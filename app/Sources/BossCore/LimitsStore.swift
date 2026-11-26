import Foundation
import Observation

public enum LimitsFetch: Equatable, Sendable {
    case ok(ProviderLimits)
    case absent                 // no subscription on this Mac: don't show the provider
    case failed                 // keep the last numbers, try again next interval
    case backoff(TimeInterval)  // the provider asked us to wait (HTTP 429 retry-after)
}

public protocol LimitsSource: Sendable {
    var id: String { get }
    /// How often to ask. Anthropic's usage endpoint punishes fast polling with long 429s.
    var interval: TimeInterval { get }
    func fetch(now: Date) async -> LimitsFetch
}

@MainActor
@Observable
public final class LimitsStore {
    public private(set) var providers: [ProviderLimits] = []
    public var expanded: Bool { didSet { saveExpanded(expanded) } }

    @ObservationIgnored let sources: [LimitsSource]
    @ObservationIgnored var nextAt: [String: Date] = [:]
    @ObservationIgnored var inFlight: Set<String> = []
    @ObservationIgnored let cacheURL: URL?
    @ObservationIgnored let saveExpanded: (Bool) -> Void
    /// Numbers older than this are dropped rather than shown as if current.
    public static let maxAge: TimeInterval = 24 * 3600

    public init(sources: [LimitsSource], cacheURL: URL? = nil, expanded: Bool = false, saveExpanded: @escaping (Bool) -> Void = { _ in }) {
        self.sources = sources
        self.cacheURL = cacheURL
        self.expanded = expanded
        self.saveExpanded = saveExpanded
        if let u = cacheURL, let d = try? Data(contentsOf: u),
           let cached = try? JSONDecoder.limits.decode([ProviderLimits].self, from: d) {
            let now = Date()
            providers = order(cached.filter { now.timeIntervalSince($0.asOf) < Self.maxAge && sources.map(\.id).contains($0.id) })
        }
    }

    /// A forced refresh (the panel just opened) asks at most this often per provider.
    public static let forceGap: TimeInterval = 120

    /// Ask every source that is due. `force` (the panel just opened) asks early, but never during a
    /// back-off and never twice within `forceGap`.
    public func tick(now: Date, force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for s in sources {
                if inFlight.contains(s.id) { continue }
                if let at = nextAt[s.id], at > now {
                    let early = force && !backingOff.contains(s.id) && now.timeIntervalSince(lastAt[s.id] ?? .distantPast) >= Self.forceGap
                    if !early { continue }
                }
                lastAt[s.id] = now
                inFlight.insert(s.id)
                group.addTask { @MainActor in
                    let r = await s.fetch(now: now)
                    self.apply(r, source: s, now: now)
                    self.inFlight.remove(s.id)
                }
            }
        }
        providers.removeAll { now.timeIntervalSince($0.asOf) >= Self.maxAge }
    }

    @ObservationIgnored var backingOff: Set<String> = []
    @ObservationIgnored var lastAt: [String: Date] = [:]

    func apply(_ r: LimitsFetch, source s: LimitsSource, now: Date) {
        backingOff.remove(s.id)
        switch r {
        case .ok(let p):
            providers.removeAll { $0.id == p.id }
            providers = order(providers + [p])
            nextAt[s.id] = now.addingTimeInterval(s.interval)
            save()
        case .absent:
            providers.removeAll { $0.id == s.id }
            nextAt[s.id] = now.addingTimeInterval(max(s.interval, 600))
            save()
        case .failed:
            nextAt[s.id] = now.addingTimeInterval(s.interval)
        case .backoff(let t):
            backingOff.insert(s.id)
            nextAt[s.id] = now.addingTimeInterval(min(max(t, 60), 3600))
        }
    }

    func order(_ p: [ProviderLimits]) -> [ProviderLimits] {
        let ids = sources.map(\.id)
        return p.sorted { (ids.firstIndex(of: $0.id) ?? 99) < (ids.firstIndex(of: $1.id) ?? 99) }
    }

    func save() {
        guard let u = cacheURL, let d = try? JSONEncoder.limits.encode(providers) else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: u, options: .atomic)
    }

    /// What a window shows now: a reset that has passed means the window starts again from empty.
    nonisolated public static func current(_ w: LimitWindow, now: Date) -> LimitWindow {
        guard let r = w.resetsAt, r <= now else { return w }
        return LimitWindow(label: w.label, used: 0, resetsAt: nil)
    }

    /// Numbers older than this are labelled with the time they were read.
    nonisolated public static func isStale(_ p: ProviderLimits, now: Date) -> Bool { now.timeIntervalSince(p.asOf) > 20 * 60 }

    /// Green under 70 %, orange to 90 %, red above (or refused right now).
    public enum Level: Equatable, Sendable { case ok, warn, high }
    nonisolated public static func level(_ used: Double) -> Level { used >= 0.9 ? .high : used >= 0.7 ? .warn : .ok }
}

extension JSONDecoder {
    static var limits: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
extension JSONEncoder {
    static var limits: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
}
