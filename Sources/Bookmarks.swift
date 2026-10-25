import Foundation
import CryptoKit

struct FavoritesAccessError: LocalizedError {
    let url: URL
    let writing: Bool
    var errorDescription: String? {
        L("Permission denied when trying to %1$@ %2$@. Add and enable Safari Bookmark Sync in Full Disk Access, then reopen this app. Existing backups are retained." , writing ? L("write") : L("read"), url.lastPathComponent)
    }
    static func isPermissionFailure(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return true }
        if value.domain == NSPOSIXErrorDomain && [1, 13].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionFailure(underlying) }
        return false
    }
}

struct BookmarkNode: Equatable {
    var title: String
    var url: String?
    var children: [BookmarkNode]
    var count: Int { (url == nil ? 0 : 1) + children.reduce(0) { $0 + $1.count } }
}

struct EdgeFavorites {
    let bar: [BookmarkNode]
    let other: [BookmarkNode]
    var count: Int { (bar + other).reduce(0) { $0 + $1.count } }
    init(bar: [BookmarkNode], other: [BookmarkNode]) { self.bar = bar; self.other = other }

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: [String: Any]], roots["bookmark_bar"] != nil else {
            throw SyncFailure.message(L("Invalid Edge bookmark file. Select the Bookmarks file inside an Edge profile."))
        }
        func parse(_ value: [String: Any]) throws -> BookmarkNode {
            let title = value["name"] as? String ?? L("Untitled")
            switch value["type"] as? String {
            case "url":
                guard let url = value["url"] as? String, !url.isEmpty else { throw SyncFailure.message(L("An Edge bookmark has no URL. Sync was stopped.")) }
                return BookmarkNode(title: title, url: url, children: [])
            case "folder":
                guard let children = value["children"] as? [[String: Any]] else { throw SyncFailure.message(L("The Edge bookmark folder data is incomplete.")) }
                return BookmarkNode(title: title, url: nil, children: try children.map(parse))
            default: throw SyncFailure.message(L("Edge contains an unsupported bookmark entry type. Sync was stopped."))
            }
        }
        bar = try parse(roots["bookmark_bar"]!).children
        var remaining = try roots["other"].map { try parse($0).children } ?? []
        for key in roots.keys.sorted() where key != "bookmark_bar" && key != "other" {
            let folder = try parse(roots[key]!)
            if !folder.children.isEmpty { remaining.append(folder) }
        }
        other = remaining
    }
}

struct SafariFavorites {
    var root: [String: Any]
    let format: PropertyListSerialization.PropertyListFormat
    init(data: Data) throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
              root["WebBookmarkType"] as? String == "WebBookmarkTypeList",
              let children = root["Children"] as? [[String: Any]],
              children.contains(where: { $0["Title"] as? String == "BookmarksBar" }),
              children.contains(where: { $0["Title"] as? String == "BookmarksMenu" }) else {
            throw SyncFailure.message(L("This Safari bookmark structure is unsupported. The original file was preserved. Confirm that you selected Bookmarks.plist."))
        }
        self.root = root
        self.format = format
    }

    static func count(_ node: [String: Any]) -> Int {
        if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" { return 1 }
        return (node["Children"] as? [[String: Any]] ?? []).reduce(0) { $0 + count($1) }
    }
    var count: Int {
        (root["Children"] as? [[String: Any]] ?? []).filter { !Self.isSystem($0) }.reduce(0) { $0 + Self.count($1) }
    }
    static func isSystem(_ node: [String: Any]) -> Bool {
        node["WebBookmarkType"] as? String == "WebBookmarkTypeProxy" || (node["Title"] as? String ?? "").hasPrefix("com.apple.")
    }
    static func entry(_ node: BookmarkNode) -> [String: Any] {
        if let url = node.url {
            return ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": UUID().uuidString,
                    "URLString": url, "URIDictionary": ["title": node.title]]
        }
        return ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString,
                "Title": node.title, "Children": node.children.map(entry)]
    }
    static func merge(_ incoming: [BookmarkNode], into existing: [[String: Any]]) -> [[String: Any]] {
        var result = existing
        for node in incoming {
            if let url = node.url {
                if !result.contains(where: { $0["URLString"] as? String == url }) { result.append(entry(node)) }
            } else if let index = result.firstIndex(where: { $0["Title"] as? String == node.title && $0["WebBookmarkType"] as? String == "WebBookmarkTypeList" }) {
                result[index]["Children"] = merge(node.children, into: result[index]["Children"] as? [[String: Any]] ?? [])
            } else { result.append(entry(node)) }
        }
        return result
    }

    func applying(_ edge: EdgeFavorites, mode: SyncMode) throws -> Data {
        guard edge.count > 0 else { throw SyncFailure.message(L("Edge bookmarks are empty. Sync was stopped without clearing Safari.")) }
        var updated = root
        let children = root["Children"] as! [[String: Any]]
        var result: [[String: Any]] = []
        for var child in children {
            let title = child["Title"] as? String
            if title == "BookmarksBar" || title == "BookmarksMenu" {
                let incoming = title == "BookmarksBar" ? edge.bar : edge.other
                child["Children"] = mode == .mirror ? incoming.map(Self.entry) : Self.merge(incoming, into: child["Children"] as? [[String: Any]] ?? [])
                result.append(child)
            } else if mode == .incremental || Self.isSystem(child) { result.append(child) }
        }
        updated["Children"] = result
        return try PropertyListSerialization.data(fromPropertyList: updated, format: format, options: 0)
    }

    var listing: String {
        func walk(_ nodes: [[String: Any]], depth: Int) -> [String] {
            nodes.flatMap { node -> [String] in
                let indent = String(repeating: "  ", count: depth)
                if let url = node["URLString"] as? String {
                    let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? L("Untitled")
                    return [indent + title, indent + url]
                }
                let title = node["Title"] as? String ?? L("Folder")
                return [indent + "▾ " + title] + walk(node["Children"] as? [[String: Any]] ?? [], depth: depth + 1)
            }
        }
        return walk(root["Children"] as? [[String: Any]] ?? [], depth: 0).joined(separator: "\n")
    }
}

struct FavoritesBackup: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let reason: String
    let count: Int
    let sha256: String
    let edgeCount: Int?
    let edgeSha256: String?
    let edgeProfilePath: String?
}

final class FavoritesBackupStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func location(_ backup: FavoritesBackup) -> URL { directory.appendingPathComponent(backup.id.uuidString, isDirectory: true) }

    @discardableResult func save(_ data: Data, edgeData: Data? = nil, edgePath: String? = nil, reason: String) throws -> FavoritesBackup {
        let document = try SafariFavorites(data: data)
        let edge = try edgeData.map { try EdgeFavorites(data: $0) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = FavoritesBackup(id: UUID(), createdAt: Date(), reason: reason, count: document.count, sha256: Self.digest(data), edgeCount: edge?.count, edgeSha256: edgeData.map(Self.digest), edgeProfilePath: edgePath)
        let staging = directory.appendingPathComponent(".pending-" + backup.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = staging.appendingPathComponent("Bookmarks.plist")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if let edgeData = edgeData {
            let edgeFile = staging.appendingPathComponent("EdgeBookmarks.json")
            try edgeData.write(to: edgeFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: edgeFile.path)
            guard Self.digest(try Data(contentsOf: edgeFile)) == backup.edgeSha256 else { throw SyncFailure.message(L("Edge backup verification failed. No sync was performed.")) }
        }
        try JSONEncoder().encode(backup).write(to: staging.appendingPathComponent("backup.json"), options: .atomic)
        guard Self.digest(try Data(contentsOf: file)) == backup.sha256 else { throw SyncFailure.message(L("Bookmark backup verification failed. The operation was stopped.")) }
        try FileManager.default.moveItem(at: staging, to: location(backup))
        return backup
    }
    func list() throws -> [FavoritesBackup] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return folders.filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { folder -> FavoritesBackup? in
            guard let backup = try? JSONDecoder().decode(FavoritesBackup.self, from: Data(contentsOf: folder.appendingPathComponent("backup.json"))),
                  backup.id == UUID(uuidString: folder.lastPathComponent) else { return nil }
            return backup
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func load(_ backup: FavoritesBackup) throws -> Data {
        let data = try Data(contentsOf: location(backup).appendingPathComponent("Bookmarks.plist"))
        guard Self.digest(data) == backup.sha256 else { throw SyncFailure.message(L("This backup is damaged and cannot be restored.")) }
        _ = try SafariFavorites(data: data)
        return data
    }
    func delete(_ backup: FavoritesBackup, recycle: (URL) throws -> Void = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }) throws {
        try recycle(location(backup))
    }
    func loadEdge(_ backup: FavoritesBackup) throws -> Data? {
        guard let checksum = backup.edgeSha256 else { return nil }
        let data = try Data(contentsOf: location(backup).appendingPathComponent("EdgeBookmarks.json"))
        guard Self.digest(data) == checksum else { throw SyncFailure.message(L("Edge backup verification failed. It cannot be restored.")) }
        _ = try EdgeFavorites(data: data)
        return data
    }
}

struct FavoritesProgress {
    let fraction: Double
    let message: String
}

final class FavoritesEngine {
    let store: FavoritesBackupStore
    let safariIsRunning: () -> Bool
    init(store: FavoritesBackupStore, safariIsRunning: @escaping () -> Bool) {
        self.store = store; self.safariIsRunning = safariIsRunning
    }
    static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) }
        catch {
            if FavoritesAccessError.isPermissionFailure(error) { throw FavoritesAccessError(url: url, writing: false) }
            throw SyncFailure.message(L("Cannot read %1$@: %2$@. Confirm that you selected the correct bookmark file." , url.lastPathComponent, error.localizedDescription))
        }
    }
    func sync(source: URL, target: URL, mode: SyncMode, progress: (FavoritesProgress) -> Void = { _ in }) throws -> String {
        guard !safariIsRunning() else { throw SyncFailure.message(L("Safari is still running. No bookmarks were updated. Quit Safari and try again.")) }
        progress(.init(fraction: 0.1, message: L("Reading Edge and Safari bookmarks…")))
        let edgeData = try Self.read(source), before = try Self.read(target)
        let edge = try EdgeFavorites(data: edgeData)
        let safari = try SafariFavorites(data: before)
        let after = try safari.applying(edge, mode: mode)
        progress(.init(fraction: 0.35, message: L("Backing up and verifying %1$@ Safari bookmarks…" , safari.count)))
        _ = try store.save(before, reason: mode == .mirror ? L("Automatic backup before bookmark mirror") : L("Automatic backup before incremental bookmark sync"))
        guard try Self.read(source) == edgeData else { throw SyncFailure.message(L("Edge bookmarks changed during preparation. Sync was stopped; try again.")) }
        try commit(after, target: target, expected: before, progress: progress)
        let finalCount = try SafariFavorites(data: after).count
        return L("%1$@ complete. Edge: %2$@ → Safari: %3$@ bookmarks. The original %4$@ bookmarks were backed up. Open Safari to inspect the result." , mode.title, edge.count, finalCount, safari.count)
    }
    func restore(_ backup: FavoritesBackup, target: URL, progress: (FavoritesProgress) -> Void = { _ in }) throws -> String {
        guard !safariIsRunning() else { throw SyncFailure.message(L("Quit Safari before restoring bookmarks.")) }
        progress(.init(fraction: 0.15, message: L("Verifying the selected bookmark backup…")))
        let restored = try store.load(backup), current = try Self.read(target)
        progress(.init(fraction: 0.35, message: L("Backing up current Safari bookmarks before restore…")))
        _ = try store.save(current, reason: L("Automatic backup before bookmark restore"))
        try commit(restored, target: target, expected: current, progress: progress)
        return L("Restored %1$@ Safari bookmarks. The previous data was saved as a separate backup." , backup.count)
    }
    private func commit(_ data: Data, target: URL, expected: Data, progress: (FavoritesProgress) -> Void) throws {
        progress(.init(fraction: 0.65, message: L("Confirming Safari has quit before writing bookmarks…")))
        guard !safariIsRunning(), try Self.read(target) == expected else {
            throw SyncFailure.message(L("Safari reopened or its bookmark file changed. No write was performed. The backup was retained."))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        do {
            try data.write(to: target, options: .atomic)
            if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path) }
        } catch {
            if FavoritesAccessError.isPermissionFailure(error) { throw FavoritesAccessError(url: target, writing: true) }
            throw SyncFailure.message(L("The bookmark write did not complete. Automatic backups were retained: %1$@" , error.localizedDescription))
        }
        progress(.init(fraction: 0.9, message: L("Reading back and verifying the bookmark file…")))
        guard try Self.read(target) == data else { throw SyncFailure.message(L("Bookmark verification failed after writing. Restore from the automatic backup.")) }
        _ = try SafariFavorites(data: data)
        progress(.init(fraction: 1, message: L("Bookmark Sync Complete")))
    }
}
