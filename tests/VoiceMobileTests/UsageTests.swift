import XCTest
import AVFoundation
@testable import VoiceMobile

@MainActor final class UsageTransport: VoiceTransport {
    var offline = false
    var failUploads = false
    var loseFirstReply = false
    var uploadNames: [String] = []
    var jobs: [String: String] = [:]
    var text = "これは保存された文字起こし本文です。"
    var polished = "読みやすく整えた文章です。"
    var summary = "# 要点\n詳しい要約には授業の結論と理由を記載しています。"
    var generationError = ""
    var concurrent = 0
    var maximumConcurrent = 0
    var uploadedDurations: [Double] = []
    func response(_ r: URLRequest, _ value: Any, status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func data(for r: URLRequest) async throws -> (Data, URLResponse) {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let path = r.url!.path
        let query = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(query.contains { $0.value == "sakura" }, "Sakura must never be used by this suite")
        if path.hasSuffix("/transcript") { return try response(r, ["status":"completed", "progress":"完了", "error":"", "text":text, "empty":text.isEmpty, "message":text.isEmpty ? "音声から文字を検出できませんでした。" : ""]) }
        if path.hasSuffix("/files") {
            var files = [["name":"音声/原文.md", "kind":"original"]]
            if !polished.isEmpty { files.append(["name":"丁寧化/丁寧版.md", "kind":"polished"]) }
            if !summary.isEmpty { files.append(["name":"要約/詳しい要約.md", "kind":"summary"]) }
            if !summary.isEmpty { files.append(["name":"要約/3行要約.md", "kind":"summary"]) }
            return try response(r, ["files":files])
        }
        if path.contains("/download/") { return (Data((path.contains("丁寧化") ? polished : summary).utf8), HTTPURLResponse(url:r.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) }
        if path.hasSuffix("/summary") { return try response(r, ["summary":[["status":"failed", "summary_mode":"detailed", "error":generationError, "progress":"失敗"]]]) }
        return try response(r, ["jobs":[]])
    }
    func upload(for r: URLRequest, fromFile file: URL) async throws -> (Data, URLResponse) {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let query = URLComponents(url:r.url!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(query.first(where:{$0.name == "stt_backend"})?.value, "local")
        let data = try Data(contentsOf:file)
        let header = String(decoding:data.prefix(512),as:UTF8.self)
        let name = header.components(separatedBy:"filename=\"")[1].components(separatedBy:"\"")[0]
        uploadNames.append(name)
        let boundary = r.value(forHTTPHeaderField:"Content-Type")!.components(separatedBy:"boundary=")[1]
        let start = data.range(of:Data("\r\n\r\n".utf8))!.upperBound
        let end = data.range(of:Data("\r\n--\(boundary)--".utf8),options:.backwards)!.lowerBound
        let audio = data.subdata(in:start..<end)
        XCTAssertEqual(String(decoding:audio.dropFirst(4).prefix(4),as:UTF8.self), "ftyp")
        XCTAssertTrue(name.hasSuffix(".m4a"))
        let extracted = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".m4a")
        try audio.write(to:extracted)
        uploadedDurations.append(RecordingFiles.duration(extracted))
        try FileManager.default.removeItem(at:extracted)
        concurrent += 1; maximumConcurrent = max(maximumConcurrent,concurrent)
        defer { concurrent -= 1 }
        try await Task.sleep(nanoseconds:150_000_000)
        if failUploads { return try response(r,["detail":"Test server unavailable"],status:503) }
        let id = jobs[name] ?? "job-\(jobs.count+1)"
        jobs[name] = id
        if loseFirstReply && uploadNames.count == 1 { throw URLError(.networkConnectionLost) }
        return try response(r,["jobs":[["id":id,"original_name":"録音.wav","status":"completed","progress":"完了"]]])
    }
}

@MainActor final class UsageTests: XCTestCase {
    func makeStore(_ supplied: UsageTransport? = nil) throws -> Store {
        let network = supplied ?? UsageTransport()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceAudit-"+UUID().uuidString)
        let store = Store(directory:folder,transport:network)
        store.server = "https://local-test.invalid/voice"; store.backend = "local"; store.sttBackend = "local"
        store.requestPermission = { true }
        store.recorderFactory = { let capture = Capture(); capture.fixtureMode = true; return capture }
        addTeardownBlock {
            await MainActor.run { store.pause(); store.stopPlayback() }
            try? FileManager.default.removeItem(at:folder)
        }
        XCTAssertTrue(store.storageReady, store.error)
        return store
    }
    func addClip(_ store: Store, title: String = "講義の録音", seconds: Double = 0.4) throws -> Clip {
        var clip = Clip(title:title,phase:"paused",revision:1,stt:"local")
        let folder = store.root.appendingPathComponent(clip.id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file = folder.appendingPathComponent("000001.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let samples = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(seconds*16000))!
        samples.frameLength = samples.frameCapacity
        for n in 0..<Int(samples.frameLength) { samples.floatChannelData![0][n] = Float(sin(Double(n)*0.1)*0.2) }
        var writer: AVAudioFile? = try AudioFileWriter.open(file,input:format)
        try writer!.write(from:samples); writer = nil
        clip.parts = [clip.id+"/000001.wav"]; clip.duration = seconds
        store.clips.append(clip); store.save()
        return clip
    }
    func waitUntil(_ test: @escaping @MainActor () -> Bool, seconds: Double = 15) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if test() { return }
            try await Task.sleep(nanoseconds:30_000_000)
        }
        XCTFail("Timed out waiting for application state")
        throw URLError(.timedOut)
    }
    func testRecordPauseResumeFinishAndRetainBackup() async throws {
        let network = UsageTransport(), store = try makeStore(network)
        await store.begin("会議の録音")
        try await waitUntil({store.seconds >= 0.3})
        XCTAssertTrue(network.uploadNames.isEmpty)
        store.pause()
        let id = store.clips[0].id, first = store.clips[0].duration
        XCTAssertGreaterThan(first,0)
        await store.resume(id)
        try await waitUntil({store.seconds > first + 0.2})
        store.finish(id)
        try await waitUntil({!store.isBusy(id)})
        XCTAssertEqual(store.clips[0].phase,"saved")
        XCTAssertEqual(store.clips[0].parts.count,2)
        XCTAssertEqual(network.uploadNames.count,1)
        XCTAssertEqual(network.uploadedDurations[0],store.clips[0].duration,accuracy:0.01)
        for part in store.clips[0].parts { XCTAssertTrue(FileManager.default.fileExists(atPath:store.root.appendingPathComponent(part).path)) }
    }
    func testStaleCaptureCallbacksCannotStopResumedRecording() async throws {
        let store = try makeStore()
        await store.begin("繰り返し再開")
        try await waitUntil({store.seconds > 0.1})
        let old = store.capture!
        store.pause(); await store.resume(store.clips[0].id)
        old.meter?(1,5399); old.failure?(URLError(.cannotWriteToFile))
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertTrue(store.recording)
        XCTAssertLessThan(store.seconds,5)
        XCTAssertTrue(store.error.isEmpty)
    }
    func testPendingUploadCannotBeResumedOrDeleted() async throws {
        let network = UsageTransport(), store = try makeStore(network)
        let clip = try addClip(store)
        store.finish(clip.id)
        await store.resume(clip.id); store.trash(clip); store.finish(clip.id)
        XCTAssertFalse(store.recording); XCTAssertFalse(store.clips[0].deleted)
        try await waitUntil({!store.isBusy(clip.id)})
        XCTAssertEqual(network.uploadNames.count,1)
    }
    func testLostResponseRenameAndRetryUsesOneServerJob() async throws {
        let network = UsageTransport(); network.loseFirstReply = true
        let store = try makeStore(network), clip = try addClip(store)
        let original = try Data(contentsOf:store.root.appendingPathComponent(clip.parts[0]))
        store.finish(clip.id)
        try await waitUntil({!store.isBusy(clip.id)})
        XCTAssertEqual(store.clips[0].phase,"paused")
        store.rename(clip.id,"変更した名前"); store.finish(clip.id)
        try await waitUntil({!store.isBusy(clip.id)})
        XCTAssertEqual(store.clips[0].phase,"saved")
        XCTAssertEqual(network.uploadNames.count,2); XCTAssertEqual(network.jobs.count,1)
        XCTAssertEqual(network.uploadNames.first,network.uploadNames.last)
        XCTAssertEqual(try Data(contentsOf:store.root.appendingPathComponent(clip.parts[0])),original)
    }
    func testErrorDiagnosisSurvivesOfflineRefresh() async throws {
        let network = UsageTransport(); network.offline = true
        let store = try makeStore(network), clip = try addClip(store)
        store.finish(clip.id)
        try await waitUntil({!store.isBusy(clip.id)})
        XCTAssertTrue(store.error.contains("サーバーへの送信"),store.error)
        XCTAssertTrue(store.error.contains("NSURLErrorDomain"),store.error)
        XCTAssertEqual(store.clips[0].phase,"paused")
        XCTAssertTrue(store.connectionMessage.contains("接続できません"))
    }
    func testQueueIsSerialAnd503CanBeRetried() async throws {
        let network = UsageTransport(); network.failUploads = true
        let store = try makeStore(network), a = try addClip(store), b = try addClip(store)
        store.finish(a.id); store.finish(b.id)
        try await waitUntil({store.pending.isEmpty && store.sendingID == nil})
        XCTAssertEqual(network.maximumConcurrent,1)
        XCTAssertTrue(store.error.contains("503"),store.error)
        network.failUploads = false
        store.finish(a.id)
        try await waitUntil({!store.isBusy(a.id)})
        XCTAssertEqual(store.clips[0].phase,"saved")
    }
    func testCorruptCatalogRecoversMetadataAndEveryRecording() throws {
        let store = try makeStore(), clip = try addClip(store,title:"失いたくない録音")
        store.rename(clip.id,"最新の名前")
        let primary = store.root.appendingPathComponent("catalog.json")
        try Data("broken-json".utf8).write(to:primary)
        let restored = Store(directory:store.root,transport:UsageTransport())
        XCTAssertEqual(restored.clips.count,1)
        XCTAssertEqual(restored.clips[0].title,"最新の名前")
        XCTAssertEqual(restored.clips[0].parts.count,1)
        XCTAssertGreaterThan(restored.clips[0].duration,0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at:store.root,includingPropertiesForKeys:nil).contains {$0.lastPathComponent.hasPrefix("catalog.invalid-")})
    }
    func testInterruptedCatalogIsResumableAndLegacyPathIsRepaired() throws {
        let store = try makeStore(), clip = try addClip(store)
        store.clips[0].phase = "recording"
        store.clips[0].parts = ["/old/container/Recordings/\(clip.id)/000001.wav"]
        store.save()
        let restored = Store(directory:store.root,transport:UsageTransport())
        XCTAssertEqual(restored.clips[0].phase,"paused")
        XCTAssertEqual(restored.clips[0].parts,[clip.id+"/000001.wav"])
    }
    func testArtifactRefreshOfflineAndAllSummaryModes() async throws {
        let network = UsageTransport(), store = try makeStore(network)
        var result = await ArtifactReading.load(["job"],kind:"original",store:store)
        XCTAssertEqual(result.text,network.text)
        network.text = "更新後の本文を取得できました。"
        result = await ArtifactReading.load(["job"],kind:"original",store:store)
        XCTAssertEqual(result.text,network.text)
        for kind in ["polished","brief","detailed"] {
            result = await ArtifactReading.load(["job"],kind:kind,store:store)
            XCTAssertFalse(result.text.isEmpty)
            network.offline = true
            let saved = await ArtifactReading.load(["job"],kind:kind,store:store)
            XCTAssertEqual(saved.text,result.text); XCTAssertTrue(saved.progress.contains("オフライン"))
            network.offline = false
        }
    }
    func testEmptyTranscriptionAndFailedSummaryAreExplicit() async throws {
        let network = UsageTransport(), store = try makeStore(network)
        _ = await ArtifactReading.load(["job"],kind:"original",store:store)
        network.text = ""
        var result = await ArtifactReading.load(["job"],kind:"original",store:store)
        XCTAssertTrue(result.text.isEmpty); XCTAssertTrue(result.progress.contains("検出できません"))
        XCTAssertNil(store.cached("job-original"))
        network.summary = ""; network.generationError = "ローカルモデルを読み込めませんでした"
        result = await ArtifactReading.load(["job"],kind:"detailed",store:store)
        XCTAssertTrue(result.failure.contains(network.generationError))
    }
    func testTrashRestoreAndLongCacheNames() throws {
        let store = try makeStore(), clip = try addClip(store)
        store.trash(clip); XCTAssertTrue(store.clips[0].deleted)
        store.trash(store.clips[0]); XCTAssertFalse(store.clips[0].deleted)
        let key = String(repeating:"長い名前/",count:120)
        store.cache(key,"本文")
        XCTAssertEqual(store.cached(key),"本文")
        XCTAssertLessThan(store.cacheURL(key).lastPathComponent.count,100)
    }
    func testMissingSegmentNeverSilentlyUploadsPartialAudio() async throws {
        let network = UsageTransport(), store = try makeStore(network), clip = try addClip(store)
        store.clips[0].parts.append(clip.id+"/missing.wav")
        store.finish(clip.id)
        XCTAssertTrue(network.uploadNames.isEmpty)
        XCTAssertEqual(store.clips[0].parts.count,2)
        XCTAssertEqual(store.clips[0].unavailableParts?.count,1)
        XCTAssertTrue(store.error.contains("録音区間"))
    }
    func testTruncatedCachedExportIsRebuilt() async throws {
        let network = UsageTransport(), store = try makeStore(network), clip = try addClip(store,seconds:0.8)
        let short = try addClip(store,seconds:0.1)
        let cached = store.root.appendingPathComponent(clip.id).appendingPathComponent("export-speech-v1-1.m4a")
        try await RecordingFiles.exportAudio([store.root.appendingPathComponent(short.parts[0])], to: cached)
        store.finish(clip.id)
        try await waitUntil({!store.isBusy(clip.id)})
        XCTAssertEqual(network.uploadedDurations[0],0.8,accuracy:0.01)
    }
    func testRestoredPendingUploadCannotRaceWithResume() async throws {
        let network = UsageTransport(), store = try makeStore(network), clip = try addClip(store)
        store.clips[0].phase = "sending"; store.save()
        let restored = Store(directory:store.root,transport:network)
        restored.server = store.server; restored.requestPermission = { true }
        restored.recorderFactory = store.recorderFactory
        await restored.resume(clip.id)
        XCTAssertFalse(restored.recording)
        restored.resumePending()
        try await waitUntil({!restored.isBusy(clip.id)})
        XCTAssertEqual(restored.clips[0].phase,"saved")
    }
    func testFull90Minutes540SegmentsAndRecordingLimit() async throws {
        let store = try makeStore()
        var clip = Clip(title:"90 minute test",phase:"paused",revision:1,stt:"local")
        let folder = store.root.appendingPathComponent(clip.id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let source = folder.appendingPathComponent("000001.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:1)!
        let samples = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:441000)!
        samples.frameLength = samples.frameCapacity
        for index in 0..<441000 { samples.floatChannelData![0][index] = Float(sin(Double(index)*0.04)*0.2) }
        var writer: AVAudioFile? = try AudioFileWriter.open(source,input:format)
        try writer!.write(from:samples); writer = nil
        clip.parts = [clip.id+"/000001.wav"]
        for index in 2...540 {
            let name = String(format:"%06d.wav",index)
            try FileManager.default.linkItem(at:source,to:folder.appendingPathComponent(name))
            clip.parts.append(clip.id+"/"+name)
        }
        clip.duration = 5400; store.clips.append(clip); store.save()
        let output = folder.appendingPathComponent("export-long.wav")
        try await RecordingFiles.export(clip.parts.map{store.root.appendingPathComponent($0)},to:output)
        XCTAssertEqual(RecordingFiles.duration(output),5400,accuracy:0.05)
        let normalized = try AVAudioFile(forReading:output)
        XCTAssertEqual(normalized.fileFormat.sampleRate,16000)
        XCTAssertLessThan(abs(normalized.length - 86400000),800)
        let restored = Store(directory:store.root,transport:UsageTransport())
        restored.requestPermission = { true }; restored.recorderFactory = store.recorderFactory
        XCTAssertEqual(restored.clips[0].parts.count,540)
        XCTAssertEqual(restored.clips[0].duration,5400,accuracy:0.05)
        await restored.resume(clip.id)
        XCTAssertFalse(restored.recording); XCTAssertTrue(restored.error.contains("90分"))
    }
}
