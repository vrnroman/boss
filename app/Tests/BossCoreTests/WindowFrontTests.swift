import Testing
import CoreGraphics
@testable import BossCore

struct WindowFrontTests {
    let me: Int32 = 100
    let panel = ScreenWindow(pid: 100, number: 1, layer: 0, bounds: CGRect(x: 3, y: 118, width: 420, height: 650))
    let chat = ScreenWindow(pid: 100, number: 2, layer: 0, bounds: CGRect(x: 431, y: 118, width: 700, height: 650))
    let menuBar = ScreenWindow(pid: 1, number: 50, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1920, height: 30))
    let iterm = ScreenWindow(pid: 200, number: 9, layer: 0, bounds: CGRect(x: 0, y: 30, width: 1920, height: 960))
    let smallFar = ScreenWindow(pid: 300, number: 10, layer: 0, bounds: CGRect(x: 1500, y: 800, width: 200, height: 100))

    @Test func coveredByAMaximisedWindowIsNotInFront() {
        // The bug Roman hit: iTerm over the whole screen, Boss behind it.
        let list = [menuBar, iterm, chat, panel]
        #expect(!WindowFront.isUnobscured(ours: [1, 2], pid: me, list: list))
        #expect(WindowFront.ringAction(panelVisible: true, unobscured: false) == .show)
    }

    @Test func onTopIsInFrontAndTheRingHidesIt() {
        let list = [menuBar, chat, panel, iterm]
        #expect(WindowFront.isUnobscured(ours: [1, 2], pid: me, list: list))
        #expect(WindowFront.ringAction(panelVisible: true, unobscured: true) == .hide)
    }

    @Test func aWindowAboveThatDoesNotOverlapDoesNotCount() {
        let list = [smallFar, chat, panel, iterm]
        #expect(WindowFront.isUnobscured(ours: [1, 2], pid: me, list: list))
    }

    @Test func theChatCoveredCountsAsObscured() {
        let overChat = ScreenWindow(pid: 300, number: 11, layer: 0, bounds: CGRect(x: 600, y: 200, width: 300, height: 300))
        let list = [panel, overChat, chat, iterm]
        #expect(!WindowFront.isUnobscured(ours: [1, 2], pid: me, list: list))
    }

    @Test func invisibleWindowsAndOtherLayersDoNotCount() {
        var ghost = iterm; ghost.alpha = 0
        #expect(WindowFront.isUnobscured(ours: [1], pid: me, list: [menuBar, ghost, panel]))
    }

    @Test func notOnScreenAtAllShows() {
        #expect(!WindowFront.isUnobscured(ours: [1], pid: me, list: [iterm]))
        #expect(WindowFront.ringAction(panelVisible: false, unobscured: false) == .show)
        #expect(WindowFront.ringAction(panelVisible: false, unobscured: true) == .show)
    }
}
