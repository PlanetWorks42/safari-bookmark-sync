import Foundation

@main struct FavoritesTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) {
        guard value else { fatalError("FAIL: " + label) }
        checks += 1; print("PASS: " + label)
    }
    static func failure(_ label: String, _ work: () throws -> Void) {
        do { try work(); fatalError("FAIL: " + label) } catch { checks += 1; print("PASS: " + label) }
    }
    static func leaf(_ name: String, _ url: String) -> BookmarkNode { .init(title: name, url: url, children: []) }
    static func folder(_ name: String, _ children: [BookmarkNode]) -> BookmarkNode { .init(title: name, url: nil, children: children) }
    static func edgeData(_ bar: [BookmarkNode], other: [BookmarkNode] = [], mobile: [BookmarkNode] = []) throws -> Data {
        func item(_ node: BookmarkNode) -> [String: Any] {
            if let url = node.url { return ["type": "url", "name": node.title, "url": url] }
            return ["type": "folder", "name": node.title, "children": node.children.map(item)]
        }
        return try JSONSerialization.data(withJSONObject: ["roots": ["bookmark_bar": item(folder("收藏夹栏", bar)), "other": item(folder("其他", other)), "synced": item(folder("移动收藏夹", mobile))]])
    }
    static func safariData() throws -> Data {
        var bar = SafariFavorites.entry(folder("BookmarksBar", [leaf("原收藏", "https://old.test/")]))
        bar["RetainCustomMetadata"] = "keep"
        let menu = SafariFavorites.entry(folder("BookmarksMenu", [leaf("原菜单", "https://menu.test/")]))
        let reading = SafariFavorites.entry(folder("com.apple.ReadingList", [leaf("阅读", "https://reading.test/")]))
        return try PropertyListSerialization.data(fromPropertyList: ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkFileVersion": 1, "RootMetadata": "preserve", "Children": [bar, menu, reading]], format: .binary, options: 0)
    }
    static func main() throws {
        check(FavoritesAccessError.isPermissionFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), "read permission errors show actionable settings flow")
        check(FavoritesAccessError.isPermissionFailure(NSError(domain: NSPOSIXErrorDomain, code: 1)), "privacy EPERM errors recognized")
        check(FavoritesAccessError.isPermissionFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)), "write permission errors recognized")
        check(!FavoritesAccessError.isPermissionFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), "missing files are not misreported as privacy permission errors")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FavoritesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let before = try safariData()
        let sourceData = try edgeData([folder("工作", [leaf("新书签", "https://new.test/?q=a#b")]), leaf("自定义协议", "custom:abc")], other: [leaf("其他", "https://other.test/")], mobile: [leaf("移动", "https://mobile.test/")])
        let edge = try EdgeFavorites(data: sourceData)
        check(edge.count == 4, "Edge counts bookmarks across bar, other and mobile roots")
        let original = try SafariFavorites(data: before)
        check(original.count == 2, "reading list is excluded from ordinary bookmark count")
        let mirrored = try SafariFavorites(data: original.applying(edge, mode: .mirror))
        check(mirrored.count == 4, "mirror replaces ordinary bookmarks")
        check(mirrored.root["RootMetadata"] as? String == "preserve", "root metadata preserved")
        let children = mirrored.root["Children"] as! [[String: Any]]
        check(children[0]["RetainCustomMetadata"] as? String == "keep", "favorites root metadata preserved")
        check(SafariFavorites.count(children[2]) == 1, "reading list preserved during mirror")
        check(mirrored.listing.contains("https://new.test/?q=a#b"), "names, query and fragment preserved")
        let mergedData = try original.applying(edge, mode: .incremental)
        let merged = try SafariFavorites(data: mergedData)
        check(merged.count == 6, "incremental retains original bookmarks")
        let repeated = try SafariFavorites(data: merged.applying(edge, mode: .incremental))
        check(repeated.count == 6, "repeated incremental is idempotent")
        let folderEdge = try EdgeFavorites(data: edgeData([folder("工作", [leaf("一", "https://one.test/")])]))
        let withFolder = try SafariFavorites(data: original.applying(folderEdge, mode: .incremental))
        let folderEdge2 = try EdgeFavorites(data: edgeData([folder("工作", [leaf("一", "https://one.test/"), leaf("二", "https://two.test/")])]))
        let mergedFolder = try SafariFavorites(data: withFolder.applying(folderEdge2, mode: .incremental))
        check(mergedFolder.count == 4, "same-name nested folders merge without duplication")
        failure("empty Edge cannot erase Safari") { _ = try original.applying(EdgeFavorites(data: edgeData([])), mode: .mirror) }
        failure("invalid Safari schema is rejected") { _ = try SafariFavorites(data: Data("not plist".utf8)) }
        failure("invalid Edge schema is rejected") { _ = try EdgeFavorites(data: Data("{}".utf8)) }
        let store = FavoritesBackupStore(directory: temp.appendingPathComponent("Backups"))
        let backup = try store.save(before, reason: "test")
        check(try store.load(backup) == before, "backup preserves the entire file exactly")
        check(try store.list().count == 1, "backup visible only after complete save")
        let source = temp.appendingPathComponent("Bookmarks"), target = temp.appendingPathComponent("Bookmarks.plist")
        try sourceData.write(to: source); try before.write(to: target)
        var progress: [Double] = []
        let engine = FavoritesEngine(store: store, safariIsRunning: { false })
        _ = try engine.sync(source: source, target: target, mode: .mirror) { progress.append($0.fraction) }
        check(try SafariFavorites(data: Data(contentsOf: target)).count == 4, "file sync writes and verifies result")
        check(progress == progress.sorted() && progress.last == 1, "progress advances through read, backup, write and verification")
        check(try store.list().count == 2, "automatic backup created before file sync")
        _ = try engine.restore(backup, target: target)
        check(try Data(contentsOf: target) == before, "restore writes the exact original file")
        check(try store.list().count == 3, "restore creates safety backup first")
        failure("Safari running prevents writing") { _ = try FavoritesEngine(store: store, safariIsRunning: { true }).sync(source: source, target: target, mode: .mirror) }
        check(try Data(contentsOf: target) == before, "blocked sync leaves Safari file untouched")
        let blocked = FavoritesBackupStore(directory: source)
        failure("backup destination failure blocks sync") { _ = try FavoritesEngine(store: blocked, safariIsRunning: { false }).sync(source: source, target: target, mode: .mirror) }
        check(try Data(contentsOf: target) == before, "failed backup cannot change target")
        var changed = false
        failure("concurrent target change aborts before write") {
            _ = try engine.sync(source: source, target: target, mode: .mirror) { step in
                if step.fraction == 0.65 { try! Data("external change".utf8).write(to: target); changed = true }
            }
        }
        let external = try Data(contentsOf: target)
        check(changed && external == Data("external change".utf8), "external changes are never overwritten")
        try before.write(to: target)
        let trash = temp.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let previousCount = try store.list().count
        try store.delete(backup) { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) }
        check(try store.list().count == previousCount - 1, "manual deletion removes only selected backup")
        check(FileManager.default.fileExists(atPath: trash.appendingPathComponent(backup.id.uuidString + "/Bookmarks.plist").path), "deleted backup is recoverable from trash")
        let another = try store.save(before, reason: "corruption test")
        try Data("bad".utf8).write(to: store.location(another).appendingPathComponent("Bookmarks.plist"))
        failure("damaged backup cannot restore") { _ = try store.load(another) }
        print("\(checks) bookmark checks passed. No real browser data was modified.")
    }
}
