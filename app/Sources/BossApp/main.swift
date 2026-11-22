import AppKit
import Darwin

// A write to a closed pipe or socket must never kill the app silently.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    ProcessInfo.processInfo.disableAutomaticTermination("Boss listens for push-to-talk")
    ProcessInfo.processInfo.disableSuddenTermination()
    withExtendedLifetime(delegate) { app.run() }
}
