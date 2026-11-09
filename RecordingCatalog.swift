import Foundation

/// A bad catalog must never silently replace the only record of saved audio.
enum RecordingCatalog {
    private struct Deletion: Codable {
        let id: String
        var files: [String]
    }

    private static func deletions(_ root: URL) throws -> [Deletion] {
        let url = root.appendingPathComponent("deleted-recordings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Deletion].self, from: Data(contentsOf: url))
    }

    static func deletionStarted(_ id: String, root: URL) throws -> Bool {
        try deletions(root).contains { $0.id == id }
    }

    private static func completeDeletions(_ pending: [Deletion], root: URL) throws {
        var completed = pending
        for index in completed.indices where !completed[index].files.isEmpty {
            for path in completed[index].files {
                let target = root.appendingPathComponent(path)
                guard relative(target, root: root) == path else { throw CocoaError(.fileWriteInvalidFileName) }
                do { try FileManager.default.removeItem(at: target) }
                catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
            }
            completed[index].files = []
        }
        if !completed.isEmpty {
            try JSONEncoder().encode(completed).write(to: root.appendingPathComponent("deleted-recordings.json"), options: .atomic)
        }
    }

    static func permanentlyDelete(_ clip: Clip, from clips: [Clip], root: URL) throws {
        guard clip.deleted, validID(clip.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let others = Set(clips.filter { $0.id != clip.id }.flatMap { other in
            other.parts.compactMap { localURL($0, clipID: other.id, root: root)?.path }
        })
        let owned = clip.parts.compactMap { localURL($0, clipID: clip.id, root: root) }
        let folder = root.appendingPathComponent(clip.id)
        guard relative(folder, root: root) == clip.id,
              !others.contains(where: { $0.hasPrefix(folder.path + "/") }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let legacy = owned.filter {
            $0.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL &&
            ["wav", "m4a"].contains($0.pathExtension.lowercased()) && !others.contains($0.path)
        }
        var pending = try deletions(root)
        if !pending.contains(where: { $0.id == clip.id }) {
            pending.append(Deletion(id: clip.id, files: [clip.id] + legacy.map(\.lastPathComponent)))
            try JSONEncoder().encode(pending).write(to: root.appendingPathComponent("deleted-recordings.json"), options: .atomic)
        }
        try completeDeletions(pending, root: root)
    }
    struct Loaded { var clips: [Clip]; var recovered: Bool }
    private static func validID(_ id: String) -> Bool { !id.isEmpty && !id.contains("/") && !id.contains("\\") && id != "." && id != ".." }
    private static func decode(_ data: Data) -> [Clip]? {
        guard let clips = try? JSONDecoder().decode([Clip].self, from: data), clips.allSatisfy({ validID($0.id) }) else { return nil }
        return clips
    }
    static func load(_ root: URL) throws -> Loaded {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = try deletions(root)
        try completeDeletions(pending, root: root)
        let deleted = Set(pending.map(\.id))
        let primary = root.appendingPathComponent("catalog.json")
        let backup = root.appendingPathComponent("catalog.backup.json")
        var clips: [Clip] = []
        var recovered = false
        if FileManager.default.fileExists(atPath: primary.path) {
            let data = try Data(contentsOf: primary)
            if let saved = decode(data) { clips = saved }
            else {
                let retained = root.appendingPathComponent("catalog.invalid-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: primary, to: retained)
                if let data = try? Data(contentsOf: backup), let saved = decode(data) { clips = saved }
                recovered = true
            }
        } else if let data = try? Data(contentsOf: backup), let saved = decode(data) {
            clips = saved; recovered = true
        }
        var seen = Set<String>()
        clips = clips.filter { !deleted.contains($0.id) && seen.insert($0.id).inserted }
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]) {
            guard !deleted.contains(folder.lastPathComponent) else { continue }
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let metadata: Clip? = {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("clip.json")), let saved = try? JSONDecoder().decode(Clip.self, from: data), saved.id == folder.lastPathComponent else { return nil }
                return saved
            }()
            if seen.contains(folder.lastPathComponent) {
                if recovered, let metadata, let index = clips.firstIndex(where: { $0.id == metadata.id }) { clips[index] = metadata }
                continue
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard metadata != nil || files.contains(where: { ["wav", "m4a"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("export-") }) else { continue }
            if let metadata { clips.append(metadata) }
            else {
                clips.append(Clip(id: folder.lastPathComponent, title: "復元した録音", date: (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(), phase: "paused"))
            }
            seen.insert(folder.lastPathComponent); recovered = true
        }
        return Loaded(clips: clips, recovered: recovered)
    }
    static func save(_ clips: [Clip], to root: URL) throws {
        guard clips.allSatisfy({ validID($0.id) }) else { throw NSError(domain:"VoiceCatalog",code:1,userInfo:[NSLocalizedDescriptionKey:"録音IDが不正です"]) }
        let primary = root.appendingPathComponent("catalog.json")
        let encoded = try JSONEncoder().encode(clips)
        if let previous = try? Data(contentsOf: primary), previous != encoded,
           decode(previous) != nil {
            try previous.write(to: root.appendingPathComponent("catalog.backup.json"), options: .atomic)
        }
        try encoded.write(to: primary, options: .atomic)
        for clip in clips {
            // Recovery metadata is kept next to its audio, independently of the list.
            let folder = root.appendingPathComponent(clip.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("clip.json")
            let data = try JSONEncoder().encode(clip)
            if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
        }
    }
    static func relative(_ url: URL, root: URL) -> String? {
        let parent = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(parent) ? String(path.dropFirst(parent.count)) : nil
    }
    static func localURL(_ part: String, clipID: String, root: URL) -> URL? {
        let candidate = root.appendingPathComponent(part).standardizedFileURL
        if relative(candidate, root: root) != nil, FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        // Older catalogs sometimes contain the former app container's absolute path.
        let name = URL(fileURLWithPath: part).lastPathComponent
        guard !name.isEmpty else { return nil }
        for url in [root.appendingPathComponent(clipID).appendingPathComponent(name), root.appendingPathComponent(name)] {
            if FileManager.default.fileExists(atPath: url.path), relative(url, root: root) != nil { return url }
        }
        return nil
    }
}
