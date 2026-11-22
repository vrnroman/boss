import AppKit
import BossCore

enum ITerm {
    static let bundleIDs = ["com.googlecode.iterm2"]

    /// Bring the iTerm tab whose session has `tty` to the front; else just activate iTerm.
    static func show(tty: String?) {
        if let tty, tty.hasPrefix("/dev/tty"), tty.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" }) {
            let src = """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      tell t to select
                      tell s to select
                      activate
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "notfound"
            """
            var err: NSDictionary?
            let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
            if r?.stringValue == "ok" { return }
        }
        activate()
    }

    static func activate() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIDs[0]).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIDs[0]) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

enum BossRestarter {
    /// Finds `boss-up` (owned by bin/): $BOSS_UP, ~/Boss/bin, the repo's bin/ next to the app, PATH.
    static func command() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let c = env["BOSS_UP"] { candidates.append(c) }
        let home = BossPaths.fromEnvironment().home.path
        candidates.append("\(home)/bin/boss-up")
        // build/Boss.app → app/ → repo/bin/boss-up
        let repoBin = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("bin/boss-up").path
        candidates.append(repoBin)
        candidates.append(repoBin + ".mjs")
        candidates.append("\(home)/bin/boss-up.mjs")
        candidates += ["/opt/homebrew/bin/boss-up", "/usr/local/bin/boss-up", "\(NSHomeDirectory())/.local/bin/boss-up", "\(NSHomeDirectory())/bin/boss-up"]
        return candidates.first {
            $0.hasSuffix(".mjs") ? FileManager.default.fileExists(atPath: $0) : FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func restart() -> Bool {
        guard let cmd = command() else { return false }
        let p = Process()
        if cmd.hasSuffix(".mjs") {
            // GUI apps get a minimal PATH; find node explicitly.
            guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [cmd, "restart"]
        } else {
            p.executableURL = URL(fileURLWithPath: cmd)
            p.arguments = ["restart"]
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return true } catch { return false }
    }
}
