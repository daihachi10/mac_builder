import Foundation

struct ResultSnapshot {
    var entries: [(String, Artifact)] = []
    var text = ""
    var failure = ""
    var progress = ""
}

@MainActor enum ArtifactReading {
    static func load(_ ids: [String], kind: String, store: Store) async -> ResultSnapshot {
        var snapshot = ResultSnapshot()
        var bodies: [String] = [], messages: [String] = [], errors: [String] = []
        for id in ids {
            if Task.isCancelled { break }
            let key = id + "-" + kind
            do {
                let files = try await store.artifacts(id)
                snapshot.entries += files.map { (id, $0) }
                if kind == "original" {
                    // A successful network read always wins over yesterday's cache.
                    let reply = try await store.transcript(id)
                    if !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        bodies.append(reply.text); store.cache(key, reply.text)
                    } else {
                        if reply.status == "completed" { store.invalidateCache(key) }
                        messages.append(!reply.message.isEmpty ? reply.message : !reply.error.isEmpty ? reply.error : "\(reply.status): \(reply.progress)")
                    }
                } else {
                    let matches = files.filter { file in file.kind == kind || (file.kind == "summary" && ((kind == "brief" && file.name.contains("3行")) || (kind == "detailed" && file.name.contains("詳しい")))) }
                    let combined = matches.filter { $0.source_path?.hasSuffix("_統合.md") == true }
                    var texts: [String] = []
                    for file in combined.isEmpty ? matches : combined {
                        let body = try await store.body(id, file.name)
                        if !body.isEmpty { texts.append(body) }
                    }
                    let text = texts.joined(separator: "\n\n──────────\n\n")
                    if !text.isEmpty { bodies.append(text); store.cache(key, text) }
                    else {
                        let route = kind == "polished" ? "polish" : "summary"
                        let data = try await store.request("/api/jobs/\(id)/\(route)")
                        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let jobs = object[route] as? [[String: Any]],
                           let job = jobs.first(where: { route == "polish" || $0["summary_mode"] as? String == kind }) {
                            let status = job["status"] as? String ?? "", error = job["error"] as? String ?? ""
                            if status == "failed" { errors.append(error.isEmpty ? "生成に失敗しました。再実行してください。" : error) }
                            else { messages.append(job["progress"] as? String ?? status) }
                            if status == "completed" { store.invalidateCache(key); messages.append("成果物が見つかりません。再作成してください。") }
                        } else { messages.append("作成メニューから生成できます。") }
                    }
                }
            } catch {
                if let text = store.cached(key), !text.isEmpty { bodies.append(text); messages.append("保存済みの本文を表示しています（オフライン）。") }
                else { errors.append(voiceErrorDescription(error)) }
            }
        }
        snapshot.text = bodies.joined(separator: "\n\n──────────\n\n")
        snapshot.failure = errors.first ?? ""; snapshot.progress = messages.first ?? ""
        return snapshot
    }
}
