import AppKit

@main struct MenuBarTests {
    static func main() {
        let screen = (frame: NSRect(x: 0, y: 0, width: 1512, height: 982), left: Optional(NSRect(x: 0, y: 950, width: 664, height: 32)), right: Optional(NSRect(x: 848, y: 950, width: 664, height: 32)))
        precondition(MenuBarVisibility.classify(item: NSRect(x: -9498, y: 945, width: 28, height: 37), screens: [screen]) == .offscreen)
        precondition(MenuBarVisibility.classify(item: NSRect(x: 744, y: 945, width: 28, height: 37), screens: [screen]) == .behindNotch)
        precondition(MenuBarVisibility.classify(item: NSRect(x: 1311, y: 945, width: 28, height: 37), screens: [screen]) == .visible)
        precondition(MenuBarVisibility.classify(item: nil, screens: [screen]) == .unavailable)
        let leftScreen: (frame: NSRect, left: NSRect?, right: NSRect?) = (NSRect(x: -1920, y: 0, width: 1920, height: 1080), nil, nil)
        precondition(MenuBarVisibility.classify(item: NSRect(x: -1000, y: 1050, width: 24, height: 24), screens: [leftScreen, screen]) == .visible)
        print("5 menu bar visibility checks passed: visible, offscreen, notch, unavailable, secondary display.")
    }
}
