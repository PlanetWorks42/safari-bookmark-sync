import Foundation
import CryptoKit

enum SyncDirection: Int, CaseIterable {
    case edgeToSafari, safariToEdge
    var title: String {
        switch self { case .edgeToSafari: return "Edge → Safari"; case .safariToEdge: return "Safari → Edge" }
    }
    var closesSafari: Bool { self != .safariToEdge }
    var closesEdge: Bool { self != .edgeToSafari }
    var requiredApps: [String] {
        (closesSafari ? ["com.apple.Safari"] : []) + (closesEdge ? ["com.microsoft.edgemac"] : [])
    }
}

extension SafariFavorites {
    func exported() throws -> EdgeFavorites {
        func convert(_ node: [String: Any]) throws -> BookmarkNode {
            let type = node["WebBookmarkType"] as? String
            if type == "WebBookmarkTypeLeaf" {
                guard let url = node["URLString"] as? String, !url.isEmpty else { throw SyncFailure.message(L("A Safari bookmark has no URL. No sync was performed.")) }
                return BookmarkNode(title: (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? L("Untitled"), url: url, children: [])
            }
            guard type == "WebBookmarkTypeList" else { throw SyncFailure.message(L("Safari contains a bookmark node that cannot be exported. No sync was performed.")) }
            return BookmarkNode(title: node["Title"] as? String ?? L("Untitled Folder"), url: nil,
                                children: try (node["Children"] as? [[String: Any]] ?? []).filter { !Self.isSystem($0) }.map(convert))
        }
        var bar: [BookmarkNode] = [], other: [BookmarkNode] = []
        for child in root["Children"] as! [[String: Any]] where !Self.isSystem(child) {
            let value = try convert(child)
            switch child["Title"] as? String {
            case "BookmarksBar": bar = value.children
            case "BookmarksMenu": other += value.children
            default: other.append(value)
            }
        }
        return EdgeFavorites(bar: bar, other: other)
    }
}

struct EdgeBookmarkDocument {
    let original: Data
    var json: [String: Any]
    var roots: [String: [String: Any]]
    init(data: Data) throws {
        _ = try EdgeFavorites(data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: [String: Any]],
              roots["bookmark_bar"] != nil, roots["other"] != nil, roots["synced"] != nil,
              json["version"] as? Int == 1 else { throw SyncFailure.message(L("This Edge bookmark version does not support safe writes. The operation was stopped.")) }
        self.original = data; self.json = json; self.roots = roots
        let checksums = try Self.checksums(roots)
        if let stored = json["checksum"] as? String, stored.lowercased() != checksums.md5 {
            throw SyncFailure.message(L("The Edge checksum is incompatible or the file is still updating. No data was written. Quit Edge and try again."))
        }
        if let stored = json["checksum_sha256"] as? String, stored.lowercased() != checksums.sha256 {
            throw SyncFailure.message(L("Edge SHA-256 verification failed. No data was written."))
        }
    }
    static func orderedRoots(_ roots: [String: [String: Any]]) -> [String] {
        ["bookmark_bar", "other", "synced"].filter { roots[$0] != nil } + roots.keys.filter { !["bookmark_bar", "other", "synced"].contains($0) }.sorted()
    }
    // Chromium codec hashes id (UTF-8), name (native UTF-16LE), type, then URL;
    // folder children follow preorder. Edge adds workspaces_v2 after synced.
    static func checksums(_ roots: [String: [String: Any]]) throws -> (md5: String, sha256: String) {
        var bytes = Data()
        func walk(_ node: [String: Any]) throws {
            guard let id = node["id"] as? String, let name = node["name"] as? String,
                  let type = node["type"] as? String, type == "folder" || type == "url" else {
                throw SyncFailure.message(L("Edge bookmarks are missing IDs or type fields. Safe writing is unavailable."))
            }
            bytes.append(Data(id.utf8)); bytes.append(name.data(using: .utf16LittleEndian)!)
            bytes.append(Data(type.utf8))
            if type == "url" {
                guard let url = node["url"] as? String else { throw SyncFailure.message(L("An Edge bookmark is missing its URL.")) }
                bytes.append(Data(url.utf8))
            } else {
                guard let children = node["children"] as? [[String: Any]] else { throw SyncFailure.message(L("The Edge folder structure is incomplete.")) }
                for child in children { try walk(child) }
            }
        }
        for key in orderedRoots(roots) { try walk(roots[key]!) }
        return (Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    func applying(_ incoming: EdgeFavorites, mode: SyncMode) throws -> Data {
        guard incoming.count > 0 else { throw SyncFailure.message(L("The source bookmarks are empty. The operation was stopped without clearing Edge.")) }
        var updatedRoots = roots
        var ids = Set<Int64>()
        func scan(_ node: [String: Any]) throws {
            guard let text = node["id"] as? String, let id = Int64(text), id > 0, ids.insert(id).inserted else {
                throw SyncFailure.message(L("Edge contains invalid or duplicate IDs. No data was written."))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { try scan(child) }
        }
        for node in roots.values { try scan(node) }
        var maxID = ids.max() ?? 0
        let timestamp = String(Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
        func entry(_ node: BookmarkNode) throws -> [String: Any] {
            guard maxID < Int64.max else { throw SyncFailure.message(L("The Edge bookmark ID range is exhausted.")) }
            maxID += 1
            var value: [String: Any] = ["id": String(maxID), "guid": UUID().uuidString.lowercased(), "name": node.title, "date_added": timestamp, "date_last_used": "0"]
            if let url = node.url { value["type"] = "url"; value["url"] = url }
            else { value["type"] = "folder"; value["date_modified"] = timestamp; value["children"] = try node.children.map(entry) }
            return value
        }
        func merge(_ incoming: [BookmarkNode], _ original: [[String: Any]]) throws -> [[String: Any]] {
            var result = original
            for node in incoming {
                if let url = node.url {
                    if !result.contains(where: { $0["type"] as? String == "url" && $0["url"] as? String == url }) { result.append(try entry(node)) }
                } else if let i = result.firstIndex(where: { $0["type"] as? String == "folder" && $0["name"] as? String == node.title }) {
                    result[i]["children"] = try merge(node.children, result[i]["children"] as? [[String: Any]] ?? [])
                } else { result.append(try entry(node)) }
            }
            return result
        }
        func setChildren(_ key: String, _ children: [BookmarkNode]) throws {
            var root = updatedRoots[key]!
            root["children"] = mode == .mirror ? try children.map(entry) : try merge(children, root["children"] as? [[String: Any]] ?? [])
            updatedRoots[key] = root
        }
        try setChildren("bookmark_bar", incoming.bar)
        var other = incoming.other
        for key in Self.orderedRoots(roots) where key != "bookmark_bar" && key != "other" {
            let name = roots[key]!["name"] as? String ?? key
            if let index = other.firstIndex(where: { $0.url == nil && $0.title == name }) {
                try setChildren(key, other.remove(at: index).children)
            } else if mode == .mirror { try setChildren(key, []) }
        }
        try setChildren("other", other)
        let before = try EdgeFavorites(data: original)
        var updated = json; updated["roots"] = updatedRoots
        let checksums = try Self.checksums(updatedRoots)
        updated["checksum"] = checksums.md5
        if json["checksum_sha256"] != nil { updated["checksum_sha256"] = checksums.sha256 }
        let result = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let after = try EdgeFavorites(data: result)
        if before.bar == after.bar && before.other == after.other { return original }
        return result
    }
}

struct BookmarkFileChange {
    let name: String
    let url: URL
    let before: Data
    let after: Data
}

final class DualFavoritesEngine {
    let store: FavoritesBackupStore
    let running: (String) -> Bool
    let writer: (Data, URL) throws -> Void
    init(store: FavoritesBackupStore, running: @escaping (String) -> Bool,
         writer: @escaping (Data, URL) throws -> Void = DualFavoritesEngine.atomicWrite) {
        self.store = store; self.running = running; self.writer = writer
    }
    static func atomicWrite(_ data: Data, _ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try data.write(to: url, options: .atomic)
            if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
            guard try FavoritesEngine.read(url) == data else { throw SyncFailure.message(L("Verification failed after writing %1$@." , url.lastPathComponent)) }
        } catch {
            if FavoritesAccessError.isPermissionFailure(error) { throw FavoritesAccessError(url: url, writing: true) }
            throw error
        }
    }
    private func ensureClosed(_ apps: [String]) throws {
        guard !apps.contains(where: running) else { throw SyncFailure.message(L("The destination browser is still running. No data was written. Quit the destination browser and try again.")) }
    }
    func sync(edgeURL: URL, safariURL: URL, direction: SyncDirection, mode: SyncMode,
              progress: (FavoritesProgress) -> Void = { _ in }) throws -> String {
        try ensureClosed(direction.requiredApps)
        progress(.init(fraction: 0.1, message: L("Reading bookmarks from both browsers…")))
        let edgeBefore = try FavoritesEngine.read(edgeURL), safariBefore = try FavoritesEngine.read(safariURL)
        let edge = try EdgeFavorites(data: edgeBefore), safari = try SafariFavorites(data: safariBefore)
        let exportedSafari = try safari.exported()
        var changes: [BookmarkFileChange] = []
        switch direction {
        case .edgeToSafari:
            changes = [.init(name: "Safari", url: safariURL, before: safariBefore, after: try safari.applying(edge, mode: mode))]
        case .safariToEdge:
            changes = [.init(name: "Edge", url: edgeURL, before: edgeBefore, after: try EdgeBookmarkDocument(data: edgeBefore).applying(exportedSafari, mode: mode))]

        }
        progress(.init(fraction: 0.35, message: L("Backing up Edge: %1$@ and Safari: %2$@ bookmarks, and verifying both files…" , edge.count, safari.count)))
        _ = try store.save(safariBefore, edgeData: edgeBefore, edgePath: edgeURL.standardizedFileURL.path, reason: direction.title + " · " + mode.title + L(" — pre-sync backup"))
        guard try FavoritesEngine.read(edgeURL) == edgeBefore, try FavoritesEngine.read(safariURL) == safariBefore else {
            throw SyncFailure.message(L("Bookmarks changed during preparation. Both backups were retained; no files were written."))
        }
        try commit(changes, requiredApps: direction.requiredApps, progress: progress)
        let finalSafari = changes.first { $0.name == "Safari" }.map(\.after) ?? safariBefore
        let finalEdge = changes.first { $0.name == "Edge" }.map(\.after) ?? edgeBefore
        return L("%1$@ complete. Edge: %2$@ bookmarks; Safari: %3$@ bookmarks. Both original bookmark files were backed up." , direction.title, try EdgeFavorites(data: finalEdge).count, try SafariFavorites(data: finalSafari).count)
    }
    func restore(_ backup: FavoritesBackup, edgeURL: URL, safariURL: URL,
                 progress: (FavoritesProgress) -> Void = { _ in }) throws -> String {
        let edgeSaved = try store.loadEdge(backup)
        let requiredApps = ["com.apple.Safari"] + (edgeSaved == nil ? [] : ["com.microsoft.edgemac"])
        try ensureClosed(requiredApps)
        if edgeSaved != nil, let path = backup.edgeProfilePath, path != edgeURL.standardizedFileURL.path {
            throw SyncFailure.message(L("This backup belongs to a different Edge profile. Select its original profile first to avoid overwriting another profile."))
        }
        let safariSaved = try store.load(backup)
        let safariBefore = try FavoritesEngine.read(safariURL), edgeBefore = try FavoritesEngine.read(edgeURL)
        progress(.init(fraction: 0.3, message: L("Backing up both browsers before restore…")))
        _ = try store.save(safariBefore, edgeData: edgeBefore, edgePath: edgeURL.standardizedFileURL.path, reason: L("Backup of both browsers before restore"))
        var changes = [BookmarkFileChange(name: "Safari", url: safariURL, before: safariBefore, after: safariSaved)]
        if let edgeSaved = edgeSaved { changes.append(.init(name: "Edge", url: edgeURL, before: edgeBefore, after: edgeSaved)) }
        try commit(changes, requiredApps: requiredApps, progress: progress)
        return edgeSaved == nil ? L("Restored a legacy Safari-only backup. Edge was not changed.") : L("Restored complete Edge and Safari bookmark files. Previous data was saved in a separate backup.")
    }
    private func commit(_ changes: [BookmarkFileChange], requiredApps: [String], progress: (FavoritesProgress) -> Void) throws {
        var attempted: [BookmarkFileChange] = []
        do {
            for (index, change) in changes.enumerated() {
                progress(.init(fraction: 0.6 + 0.3 * Double(index) / Double(changes.count), message: L("Writing and verifying %1$@ bookmarks…" , change.name)))
                try ensureClosed(requiredApps)
                for other in changes {
                    let expected = attempted.contains { $0.url == other.url } ? other.after : other.before
                    guard try FavoritesEngine.read(other.url) == expected else { throw SyncFailure.message(L("Another process changed the bookmarks. Writing was stopped.")) }
                }
                attempted.append(change)
                if change.before != change.after { try writer(change.after, change.url) }
                guard try FavoritesEngine.read(change.url) == change.after else { throw SyncFailure.message(L("%1$@ verification failed." , change.name)) }
            }
            progress(.init(fraction: 1, message: L("Bookmark Sync Complete")))
        } catch {
            var rollbackFailed = false
            for change in attempted.reversed() where change.before != change.after {
                do {
                    try ensureClosed(requiredApps)
                    let current = try FavoritesEngine.read(change.url)
                    if current == change.after { try writer(change.before, change.url) }
                    else if current != change.before { rollbackFailed = true }
                } catch { rollbackFailed = true }
            }
            if attempted.isEmpty || (error is FavoritesAccessError && !rollbackFailed) { throw error }
            throw SyncFailure.message(error.localizedDescription + (rollbackFailed ? L(" Automatic rollback could not finish. Restore from the backups of both browsers.") : L(" This write was rolled back. Both backups were retained.")))
        }
    }
}
