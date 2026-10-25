import Foundation

@main struct DirectionTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) { guard value else { fatalError("FAIL: " + label) }; checks += 1; print("PASS: " + label) }
    static func failure(_ label: String, _ work: () throws -> Void) { do { try work(); fatalError("FAIL: " + label) } catch { checks += 1; print("PASS: " + label) } }
    static func leaf(_ title: String, _ url: String) -> BookmarkNode { .init(title: title, url: url, children: []) }
    static func folder(_ title: String, _ nodes: [BookmarkNode]) -> BookmarkNode { .init(title: title, url: nil, children: nodes) }
    static func safariFixture(empty: Bool = false) throws -> Data {
        let bar = SafariFavorites.entry(folder("BookmarksBar", empty ? [] : [leaf("Safari 专用", "https://safari.test/"), folder("工作", [leaf("报告", "https://report.test/")])]))
        let menu = SafariFavorites.entry(folder("BookmarksMenu", empty ? [] : [leaf("Safari 菜单", "https://safari-menu.test/")]))
        let reading = SafariFavorites.entry(folder("com.apple.ReadingList", [leaf("阅读", "https://read.test/")]))
        return try PropertyListSerialization.data(fromPropertyList: ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkFileVersion": 1, "Children": [bar, menu, reading]], format: .binary, options: 0)
    }
    static func edgeFixture(empty: Bool = false) throws -> Data {
        var number = 10
        func entry(_ node: BookmarkNode) -> [String: Any] {
            number += 1
            var data: [String: Any] = ["id": String(number), "guid": UUID().uuidString.lowercased(), "name": node.title, "date_added": "1234", "custom_metadata": "preserve"]
            if let url = node.url { data["type"] = "url"; data["url"] = url }
            else { data["type"] = "folder"; data["children"] = node.children.map(entry) }
            return data
        }
        let roots = ["bookmark_bar": entry(folder("收藏夹栏", empty ? [] : [leaf("Edge 专用", "https://edge.test/"), folder("工作", [leaf("设计", "https://design.test/")])])),
                     "other": entry(folder("其他收藏夹", empty ? [] : [leaf("Edge 其他", "https://edge-other.test/")])),
                     "synced": entry(folder("移动收藏夹", empty ? [] : [leaf("移动", "https://mobile.test/")])),
                     "workspaces_v2": entry(folder("工作区", []))]
        let digest = try EdgeBookmarkDocument.checksums(roots)
        return try JSONSerialization.data(withJSONObject: ["version": 1, "roots": roots, "checksum": digest.md5, "checksum_sha256": digest.sha256, "sync_metadata": "original-metadata"])
    }
    static func main() throws {
        check(SyncDirection.edgeToSafari.rawValue == 0 && SyncDirection.allCases.count == 2, "two directions, Edge to Safari is default")
        let edgeBefore = try edgeFixture(), safariBefore = try safariFixture()
        let edge = try EdgeFavorites(data: edgeBefore), safari = try SafariFavorites(data: safariBefore)
        let exported = try safari.exported()
        check(exported.count == 3, "Safari export excludes reading list")
        let edgeDoc = try EdgeBookmarkDocument(data: edgeBefore)
        let mirrorData = try edgeDoc.applying(exported, mode: .mirror)
        let mirrored = try EdgeFavorites(data: mirrorData)
        check(mirrored.count == 3 && mirrored.bar == exported.bar && mirrored.other == exported.other, "Safari to Edge pure mirror replaces target accurately")
        let checked = try EdgeBookmarkDocument(data: mirrorData)
        check(checked.json["sync_metadata"] as? String == "original-metadata", "Edge root sync metadata preserved")
        check(checked.roots["bookmark_bar"]?["custom_metadata"] as? String == "preserve", "Edge permanent root metadata preserved")
        let incrementalData = try edgeDoc.applying(exported, mode: .incremental)
        let incremental = try EdgeFavorites(data: incrementalData)
        check(incremental.count == 7, "Safari to Edge incremental retains both sets")
        let repeatData = try EdgeBookmarkDocument(data: incrementalData).applying(exported, mode: .incremental)
        check(repeatData == incrementalData, "repeat reverse incremental does not rewrite file or duplicate bookmarks")
        let roundTrip = try EdgeBookmarkDocument(data: edgeBefore).applying(edge, mode: .incremental)
        check(roundTrip == edgeBefore, "mobile root round trip does not duplicate it into other bookmarks")
        var ids: [String] = [], guids: [String] = []
        func walk(_ node: [String: Any]) {
            ids.append(node["id"] as! String); guids.append(node["guid"] as! String)
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for root in try EdgeBookmarkDocument(data: incrementalData).roots.values { walk(root) }
        check(ids.count == Set(ids).count && guids.count == Set(guids).count, "new Edge entries have unique IDs and GUIDs")
        var corrupted = edgeDoc.json; corrupted["checksum"] = "bad"
        failure("incompatible Edge checksum blocks writing") { _ = try EdgeBookmarkDocument(data: JSONSerialization.data(withJSONObject: corrupted)) }
        failure("empty Safari cannot mirror-clear Edge") { _ = try edgeDoc.applying(SafariFavorites(data: safariFixture(empty: true)).exported(), mode: .mirror) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("DirectionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let edgeURL = temp.appendingPathComponent("Bookmarks"), safariURL = temp.appendingPathComponent("Bookmarks.plist")
        let store = FavoritesBackupStore(directory: temp.appendingPathComponent("Backups"))
        let engine = DualFavoritesEngine(store: store, running: { _ in false })
        for direction in SyncDirection.allCases {
            for mode in [SyncMode.incremental, .mirror] {
                try edgeBefore.write(to: edgeURL); try safariBefore.write(to: safariURL)
                _ = try engine.sync(edgeURL: edgeURL, safariURL: safariURL, direction: direction, mode: mode)
                let newEdge = try Data(contentsOf: edgeURL), newSafari = try Data(contentsOf: safariURL)
                if direction == .edgeToSafari {
                    check(newEdge == edgeBefore, "Edge to Safari leaves source bytes untouched (\(mode))")
                    check(try SafariFavorites(data: newSafari).count == (mode == .mirror ? 4 : 7), "Edge to Safari target correct (\(mode))")
                } else {
                    check(newSafari == safariBefore, "Safari to Edge leaves source bytes untouched (\(mode))")
                    check(try EdgeFavorites(data: newEdge).count == (mode == .mirror ? 3 : 7), "Safari to Edge target correct (\(mode))")
                    _ = try EdgeBookmarkDocument(data: newEdge)
                }
                let latest = try store.list()[0]
                check(try store.load(latest) == safariBefore && store.loadEdge(latest) == edgeBefore, "both files backed up before each direction/mode (\(direction), \(mode))")
            }
        }
        try edgeBefore.write(to: edgeURL); try safariBefore.write(to: safariURL)
        for direction in SyncDirection.allCases {
            failure("running target blocks \(direction)") { _ = try DualFavoritesEngine(store: store, running: { direction.requiredApps.contains($0) }).sync(edgeURL: edgeURL, safariURL: safariURL, direction: direction, mode: .mirror) }
        }
        let pair = try store.save(safariBefore, edgeData: edgeBefore, edgePath: edgeURL.standardizedFileURL.path, reason: "pair")
        try mirrorData.write(to: edgeURL)
        let changedSafari = try safari.applying(edge, mode: .mirror)
        try changedSafari.write(to: safariURL)
        _ = try engine.restore(pair, edgeURL: edgeURL, safariURL: safariURL)
        check(try Data(contentsOf: edgeURL) == edgeBefore && Data(contentsOf: safariURL) == safariBefore, "restore returns both exact original files")
        let differentProfile = temp.appendingPathComponent("OtherBookmarks")
        try edgeBefore.write(to: differentProfile)
        failure("restore cannot overwrite a different Edge profile") { _ = try engine.restore(pair, edgeURL: differentProfile, safariURL: safariURL) }
        try mirrorData.write(to: edgeURL); try changedSafari.write(to: safariURL)
        var failOnce = true
        let failing = DualFavoritesEngine(store: store, running: { _ in false }) { data, url in
            if url == edgeURL && failOnce { failOnce = false; throw SyncFailure.message("simulated second-file failure") }
            try DualFavoritesEngine.atomicWrite(data, url)
        }
        failure("second-file restore failure triggers rollback") { _ = try failing.restore(pair, edgeURL: edgeURL, safariURL: safariURL) }
        check(try Data(contentsOf: safariURL) == changedSafari && Data(contentsOf: edgeURL) == mirrorData, "partial restore rolls back first file without overwriting second")
        let legacy = try store.save(safariBefore, reason: "Safari-only backup")
        check(try store.loadEdge(legacy) == nil, "old Safari-only backups remain readable")
        print("\(checks) direction checks passed. No real browser data modified.")
    }
}
