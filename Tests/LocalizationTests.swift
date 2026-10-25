import Foundation

@main struct LocalizationTests {
    static func main() {
        let result = L("Restore the %2$@ bookmarks from %1$@.", "2026-10-25", "Edge and Safari")
        precondition(result == "Restore the Edge and Safari bookmarks from 2026-10-25.")
        let percent = L("Value: %1$@", "100%")
        precondition(percent == "Value: 100%")
        precondition(L("Plain English") == "Plain English")
        print("3 localization runtime checks passed: positional arguments, literal percent, fallback.")
    }
}
