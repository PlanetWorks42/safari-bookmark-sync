import Foundation

enum SyncMode: Int {
    case incremental = 0
    case mirror = 1
    var title: String { self == .mirror ? L("Mirror") : L("Incremental") }
}

enum SyncFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
