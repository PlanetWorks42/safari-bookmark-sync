import Foundation

enum AppLanguage {
    static var identifier: String {
        let selection = ProcessInfo.processInfo.environment["SAFARI_SYNC_LANGUAGE"]
            ?? UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if selection == "en" || selection == "zh-Hans" { return selection }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? "zh-Hans" : "en"
    }
    static var locale: Locale { Locale(identifier: identifier) }
    static var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"), let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

/// Localized application text. Positional %@ arguments preserve translator ordering.
func L(_ key: String, _ arguments: Any...) -> String {
    let value = AppLanguage.bundle.localizedString(forKey: key, value: key, table: "Localizable")
    guard !arguments.isEmpty else { return value }
    return String(format: value, locale: AppLanguage.locale, arguments: arguments.map { String(describing: $0) as NSString })
}
