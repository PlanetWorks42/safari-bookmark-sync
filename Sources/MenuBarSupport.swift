import AppKit

enum MenuBarVisibility: String {
    case visible, offscreen, behindNotch, unavailable
    static func classify(item: NSRect?, screens: [(frame: NSRect, left: NSRect?, right: NSRect?)]) -> MenuBarVisibility {
        guard let item = item, item.width > 0, item.height > 0 else { return .unavailable }
        let center = NSPoint(x: item.midX, y: item.midY)
        guard let screen = screens.first(where: { $0.frame.contains(center) }) else { return .offscreen }
        if let left = screen.left, let right = screen.right, center.y >= min(left.minY, right.minY),
           !left.contains(center), !right.contains(center) { return .behindNotch }
        return .visible
    }
}
