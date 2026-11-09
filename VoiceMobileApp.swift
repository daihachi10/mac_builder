import SwiftUI
import AVFoundation
import UIKit
import CryptoKit

private let voiceAppVersion: String = {
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(version) (\(build))"
}()

struct Job: Decodable, Identifiable { let id: String; let original_name: String; let status: String; let progress: String }
struct Artifact: Decodable { let name: String; let kind: String; let source_path: String? }
struct JobsReply: Decodable { let jobs: [Job] }
struct FilesReply: Decodable { let files: [Artifact] }
struct TranscriptReply: Decodable {
    let status: String
    let progress: String
    let error: String
    let text: String
    let empty: Bool
    let message: String
}

final class Capture: @unchecked Sendable {
    let engine = AVAudioEngine()
    let lock = NSLock()
    var file: AVAudioFile?
    var url: URL?
    var format: AVAudioFormat!
    var folder: URL!
    var index = 0
    var frames: Int64 = 0
    var total: Int64 = 0
    var lastMeter: Double = 0
    var part: ((URL) -> Void)?
    var meter: ((Float, Double) -> Void)?
    var failure: ((Error) -> Void)?
    #if DEBUG
    var fixtureMode = false
    var fixtureTimer: Timer?
    #endif
    var isRunning: Bool {
        #if DEBUG
        if fixtureMode { return fixtureTimer?.isValid == true }
        #endif
        return engine.isRunning
    }
    func open() throws {
        index += 1
        url = folder.appendingPathComponent(String(format: "%06d.wav", index))
        file = try AudioFileWriter.open(url!, input: format)
        frames = 0
    }
    func start(folder: URL) throws {
        self.folder = folder
        index = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }.max() ?? 0
        #if DEBUG
        if fixtureMode {
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            try open()
            fixtureTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.file != nil else { return }
                do {
                    let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: 4410)!
                    buffer.frameLength = 4410
                    for i in 0..<4410 { buffer.floatChannelData![0][i] = Float(sin(Double(self.total + Int64(i)) * 0.05) * 0.2) }
                    try self.file!.write(from: buffer)
                    self.frames += 4410; self.total += 4410
                    self.meter?(0.2, Double(self.total) / self.format.sampleRate)
                    if self.frames >= 441000 { let done = self.url!; self.file = nil; self.part?(done); try self.open() }
                } catch { self.file = nil; self.failure?(error) }
            }
            RunLoop.main.add(fixtureTimer!, forMode: .common)
            return
        }
        #endif
        let session = AVAudioSession.sharedInstance()
        var started = false
        defer { if !started { try? session.setActive(false) } }
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(44100)
        try session.setActive(true)
        if session.maximumInputNumberOfChannels > 0 { try? session.setPreferredInputNumberOfChannels(1) }
        format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw URLError(.cannotDecodeRawData) }
        do { try open() } catch { try? session.setActive(false); throw error }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.file != nil else { return }
            do {
                try self.file?.write(from: buffer)
                self.frames += Int64(buffer.frameLength); self.total += Int64(buffer.frameLength)
                let elapsed = Double(self.total) / self.format.sampleRate
                if elapsed - self.lastMeter >= 0.1 {
                    self.lastMeter = elapsed
                    var peak: Float = 0
                    if let samples = buffer.floatChannelData?[0] { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) } }
                    self.meter?(peak, elapsed)
                }
                // Closed checkpoints are backups only. Never upload while recording.
                if Double(self.frames) / self.format.sampleRate >= 10 {
                    let completed = self.url!
                    self.file = nil
                    self.part?(completed)
                    try self.open()
                }
            } catch { self.file = nil; self.failure?(error) }
        }
        do { try engine.start() }
        catch { engine.inputNode.removeTap(onBus: 0); file = nil; try? session.setActive(false); throw error }
        started = true
    }
    func stop() -> (URL?, Double) {
        #if DEBUG
        if fixtureMode { fixtureTimer?.invalidate(); fixtureTimer = nil }
        else { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        #else
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        #endif
        lock.lock()
        let completed = frames > 0 ? url : nil
        let elapsed = format == nil ? 0 : Double(total) / format.sampleRate
        file = nil
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false)
        return (completed, elapsed)
    }
}

@MainActor final class Store: NSObject, ObservableObject {
    @Published var clips: [Clip] = []
    @Published var jobs: [Job] = []
    @Published var recording = false
    @Published var seconds: Double = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 50)
    @Published var active: String?
    @Published var error = ""
    @Published var connectionMessage = ""
    @Published var sendingID: String?
    @Published var sendStatus = ""
    @Published var isPlaying = false
    @Published var playingID: String?
    @Published var playTime: Double = 0
    @Published var playDuration: Double = 0
    @AppStorage("serverURL") var server = ""
    @Published var needsServerSettings = false
    @Published var exportingID: String?
    @AppStorage("backend") var backend = "local"
    @AppStorage("sttBackend") var sttBackend = "local"
    @AppStorage("appearance") var appearance = "system"
    let root: URL
    let transport: any VoiceTransport
    var recorderFactory: () -> Capture = { Capture() }
    var requestPermission: () async -> Bool = { await AVAudioApplication.requestRecordPermission() }
    var storageReady = true
    var starting = false
    var capture: Capture?
    var baseDuration: Double = 0
    var lastSave: Double = 0
    var pending: [String] = []
    var player: AVAudioPlayer?
    var playbackURLs: [URL] = []
    var timeline = PlaybackTimeline(durations: [])
    var playbackIndex = 0
    var playbackTimer: Timer?
    var preview: Bool { ProcessInfo.processInfo.arguments.contains("--ui-preview") }
    override convenience init() {
        self.init(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings"))
    }
    init(directory: URL, transport: any VoiceTransport = NetworkTransport()) {
        root = directory
        self.transport = transport
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--upload-self-test") {
            Task {
                let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("upload-self-test.txt")
                do { try await AudioFormatChecks.run(); try "PASS iOS PCM upload preparation".write(to: report, atomically: true, encoding: .utf8) }
                catch { try? ("FAIL " + voiceErrorDescription(error)).write(to: report, atomically: true, encoding: .utf8) }
            }
        }
        #endif
        if preview {
            clips = [Clip(title: "歴史", duration: 3532, phase: "saved", finalJob: "preview-job"), Clip(title: "新規録音", duration: 794, phase: "saved")]
            if ProcessInfo.processInfo.arguments.contains("--ui-recording") || ProcessInfo.processInfo.arguments.contains("--ui-home-recording") {
                active = clips[0].id; recording = true; seconds = 225; clips[0].duration = 225; clips[0].phase = "recording"
                levels = (0..<50).map { Float(abs(sin(Double($0) * 0.8)) * 0.7) }
            }
            return
        }
        do {
            let loaded = try RecordingCatalog.load(root); clips = loaded.clips
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            if loaded.recovered { connectionMessage = "保存済みの音声から録音一覧を復元しました。" }
        } catch { storageReady = false; self.error = "録音一覧を開けませんでした。\n\(voiceErrorDescription(error))" }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in files where storageReady && ["m4a", "wav"].contains(url.pathExtension) {
            if !clips.contains(where: { $0.parts.contains(url.lastPathComponent) }) {
                clips.append(Clip(title: url.deletingPathExtension().lastPathComponent, parts: [url.lastPathComponent], phase: "paused"))
            }
        }
        for i in clips.indices {
            // Rebuild the catalog from closed/repairable local files after interruption.
            reconcile(i)
            if clips[i].phase == nil { clips[i].phase = clips[i].jobIDs.isEmpty ? "paused" : "saved" }
            if clips[i].phase == "recording" { clips[i].phase = "paused" }
            if clips[i].phase == "sending" { clips[i].phase = "ready" }
        }
        save()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    func save() {
        guard !preview, storageReady else { return }
        do { try RecordingCatalog.save(clips, to: root) }
        catch { self.error = error.localizedDescription }
    }
    func reconcile(_ i: Int) {
        let folder = root.appendingPathComponent(clips[i].id)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" && !$0.lastPathComponent.hasPrefix("export-") }
        let recovered = urls.compactMap { RecordingFiles.recover($0) }
        var missing: [String] = []
        let known = clips[i].parts.compactMap { part -> URL? in
            guard let url = RecordingCatalog.localURL(part, clipID: clips[i].id, root: root), let playable = RecordingFiles.recover(url) else { missing.append(part); return nil }
            return playable
        }
        let unique = Dictionary((recovered + known).filter { RecordingFiles.duration($0) > 0 }.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = unique.values.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // Prefer repaired copies over their invalid originals.
        clips[i].parts = sorted.compactMap { RecordingCatalog.relative($0, root: root) } + missing
        clips[i].unavailableParts = missing.isEmpty ? nil : missing
        clips[i].duration = sorted.reduce(0) { $0 + RecordingFiles.duration($1) }
    }
    func endpoint(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        let base = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var c = URLComponents(string: base), c.scheme == "https", c.host != nil, c.user == nil else { throw URLError(.badURL) }
        c.path += path; c.queryItems = query.isEmpty ? nil : query
        guard let result = c.url else { throw URLError(.badURL) }
        return result
    }
    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        var r = URLRequest(url: try endpoint(path, query)); r.httpMethod = method; r.timeoutInterval = 30
        let (data, response) = try await transport.data(for: r)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Voice", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(String(data: data.prefix(300), encoding: .utf8) ?? "接続失敗")"])
        }
        return data
    }
    func refresh(showError: Bool = false) async {
        guard !preview else { return }
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if showError { error = "設定に文字起こしサーバーのHTTPS URLを入力してください。" }
            return
        }
        do { jobs = try JSONDecoder().decode(JobsReply.self, from: await request("/api/jobs")).jobs; connectionMessage = "" }
        catch {
            connectionMessage = "サーバーに接続できません。録音は端末内に保存できます。"
            if showError, self.error.isEmpty { self.error = "Tailscaleと接続先URLを確認してください。\n\(voiceErrorDescription(error))" }
        }
    }
    func artifacts(_ id: String) async throws -> [Artifact] { try JSONDecoder().decode(FilesReply.self, from: await request("/api/jobs/\(id)/files")).files }
    func transcript(_ id: String) async throws -> TranscriptReply {
        try JSONDecoder().decode(TranscriptReply.self, from: await request("/api/mobile/jobs/\(id)/transcript"))
    }
    func body(_ id: String, _ file: String) async throws -> String {
        let data = try await request("/api/jobs/\(id)/download/" + file)
        guard let value = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return value
    }
    func cacheURL(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("TextCache").appendingPathComponent(name + ".txt")
    }
    func cache(_ key: String, _ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let path = cacheURL(key)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? value.write(to: path, atomically: true, encoding: .utf8)
    }
    func cached(_ key: String) -> String? {
        if let current = try? String(contentsOf: cacheURL(key), encoding: .utf8) { return current }
        let legacy = root.appendingPathComponent("TextCache").appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".txt")
        return try? String(contentsOf: legacy, encoding: .utf8)
    }
    func invalidateCache(_ key: String) {
        try? FileManager.default.removeItem(at: cacheURL(key))
        let legacy = root.appendingPathComponent("TextCache").appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".txt")
        try? FileManager.default.removeItem(at: legacy)
    }
    func generate(_ job: String, _ file: String, _ action: String, _ mode: String) async throws {
        _ = try await request("/api/jobs/\(job)/\(action)", method: "POST", query: [.init(name: "file_path", value: file), .init(name: "backend", value: backend), .init(name: "mode", value: mode), .init(name: "force", value: "1")])
    }
    func begin(_ title: String) async {
        guard !recording, !starting, storageReady else { return }
        let clip = Clip(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新規録音" : title, stt: sttBackend)
        clips.insert(clip, at: 0); save()
        await resume(clip.id)
    }
    func resume(_ id: String) async {
        guard !recording, !starting, storageReady, !uploadLocked(id), clips.contains(where: { $0.id == id && !$0.deleted }) else { return }
        starting = true
        defer { starting = false }
        let granted = await requestPermission()
        guard granted else { error = "設定でマイクの使用を許可してください"; return }
        guard !recording, !uploadLocked(id), let i = clips.firstIndex(where: { $0.id == id && !$0.deleted }) else { return }
        stopPlayback(); reconcile(i)
        guard clips[i].unavailableParts?.isEmpty != false else { error = "録音区間の一部を読み込めません。保存済みファイルを確認してください。"; return }
        baseDuration = clips[i].duration
        guard baseDuration < 5400 else { error = "この録音は90分に達しています。完了して送信してください。"; return }
        do {
            let folder = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            active = id; seconds = baseDuration; lastSave = baseDuration
            let audio = recorderFactory()
            audio.part = { [weak self] url in Task { @MainActor in self?.checkpoint(id, url) } }
            audio.meter = { [weak self, weak audio] level, duration in Task { @MainActor in
                guard let self, let audio, self.recording, self.active == id, self.capture === audio else { return }
                self.seconds = self.baseDuration + duration
                self.levels.append(level); self.levels = Array(self.levels.suffix(50))
                if let i = self.clips.firstIndex(where: { $0.id == id }) {
                    self.clips[i].duration = self.seconds
                    if self.seconds - self.lastSave >= 5 { self.lastSave = self.seconds; self.save() }
                }
                if self.seconds >= 5400 { self.finish(id) }
            } }
            audio.failure = { [weak self, weak audio] error in Task { @MainActor in
                guard let self, let audio, self.capture === audio else { return }
                self.pause(); self.error = "録音を中断しました。保存済み部分から再開できます。\n\(voiceErrorDescription(error))"
            } }
            // Persist the new generation before creating even the first audio file.
            clips[i].phase = "recording"; clips[i].revision = (clips[i].revision ?? 0) + 1
            clips[i].finalJob = nil
            try RecordingCatalog.save(clips, to: root)
            capture = audio
            try audio.start(folder: folder)
            recording = true
            save()
        } catch { recording = false; capture = nil; clips[i].phase = "paused"; self.error = error.localizedDescription; save() }
    }
    func checkpoint(_ id: String, _ url: URL) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let part = "\(id)/\(url.lastPathComponent)"
        if !clips[i].parts.contains(part) { clips[i].parts.append(part) }
        save()
    }
    func pause() {
        guard recording, let id = active else { return }
        recording = false
        if let snapshot = capture?.stop() {
            seconds = baseDuration + snapshot.1
            if let url = snapshot.0 { checkpoint(id, url) }
        }
        capture = nil
        if let i = clips.firstIndex(where: { $0.id == id }) { reconcile(i); seconds = clips[i].duration; clips[i].phase = "paused" }
        save()
    }
    func finish(_ id: String) {
        guard !isBusy(id) else { return }
        if recording && active == id { pause() }
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            needsServerSettings = true
            return
        }
        guard let i = clips.firstIndex(where: { $0.id == id && !$0.deleted }) else { return }
        reconcile(i)
        guard clips[i].unavailableParts?.isEmpty != false else { error = "録音区間の一部を読み込めないため、送信を止めました。残りの録音は保存されています。"; return }
        guard !clips[i].parts.isEmpty else { error = "録音された音声がありません"; return }
        clips[i].phase = "ready"; save()
        send(clips[i])
    }
    func send(_ clip: Clip) {
        guard !(recording && active == clip.id), !isBusy(clip.id), !clip.deleted else { return }
        pending.append(clip.id)
        if sendingID == nil { Task { await drain() } }
    }
    func resumePending() {
        guard !preview, !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for clip in clips where clip.phase == "ready" && !clip.deleted { send(clip) }
    }
    func drain() async {
        guard sendingID == nil else { return }
        while !pending.isEmpty {
            let id = pending.removeFirst()
            guard let i = clips.firstIndex(where: { $0.id == id && !$0.deleted }) else { continue }
            sendingID = id; clips[i].phase = "sending"; save()
            var stage = "録音の結合"
            do {
                let clip = clips[i]
                guard clip.unavailableParts?.isEmpty != false else { throw NSError(domain: "VoiceAudio", code: 4, userInfo: [NSLocalizedDescriptionKey: "録音区間の一部を読み込めません"]) }
                sendStatus = "録音を1つのファイルにまとめています…"
                let exported = root.appendingPathComponent(id).appendingPathComponent("export-pcm-v2-\(clip.revision ?? 0).wav")
                let cachedDuration = RecordingFiles.duration(exported)
                if cachedDuration <= 0 || abs(cachedDuration - clip.duration) > max(0.01, clip.duration * 0.0001) {
                    try FileManager.default.createDirectory(at: exported.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await RecordingFiles.export(clip.parts.map { root.appendingPathComponent($0) }, to: exported)
                }
                sendStatus = "録音を送信中…"
                stage = "送信データの準備"
                let boundary = UUID().uuidString
                let temp = root.appendingPathComponent("\(boundary).tmp")
                defer { try? FileManager.default.removeItem(at: temp) }
                // Stable identity survives rename and a lost HTTP response.
                let filename = "\(id)_r\(clip.revision ?? 0)_\(clip.stt ?? "local").wav"
                FileManager.default.createFile(atPath: temp.path, contents: nil)
                let destination = try FileHandle(forWritingTo: temp)
                let source = try FileHandle(forReadingFrom: exported)
                do {
                    try destination.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
                    while let block = try source.read(upToCount: 1024 * 1024), !block.isEmpty { try destination.write(contentsOf: block) }
                    try destination.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
                    try source.close(); try destination.close()
                } catch { try? source.close(); try? destination.close(); throw error }
                var r = URLRequest(url: try endpoint("/api/uploads", [.init(name: "stt_backend", value: clip.stt ?? "local"), .init(name: "display_name", value: String(clip.title.prefix(160)))]))
                r.httpMethod = "POST"; r.timeoutInterval = 600
                r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                stage = "サーバーへの送信"
                let (reply, response) = try await transport.upload(for: r, fromFile: temp)
                stage = "サーバー応答の確認"
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "Upload", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: String(data: reply.prefix(600), encoding: .utf8) ?? "送信失敗"])
                }
                guard let job = try JSONDecoder().decode(JobsReply.self, from: reply).jobs.first else { throw URLError(.cannotParseResponse) }
                if let j = clips.firstIndex(where: { $0.id == id }) { clips[j].finalJob = job.id; clips[j].phase = "saved"; save() }
                sendStatus = "送信完了。文字起こし処理を待っています。"
            } catch {
                if let j = clips.firstIndex(where: { $0.id == id }) { clips[j].phase = "paused"; save() }
                self.error = "\(stage)に失敗しました。録音は端末に保存されています。\n\(voiceErrorDescription(error))\n音声ノート \(voiceAppVersion)"
                try? self.error.write(to: root.appendingPathComponent(id).appendingPathComponent("upload-error.txt"), atomically: true, encoding: .utf8)
            }
            sendingID = nil
        }
        await refresh()
    }
    func rename(_ id: String, _ title: String) { if let i = clips.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clips[i].title = title; save() } }
    func isBusy(_ id: String) -> Bool { sendingID == id || pending.contains(id) || exportingID == id }

    func exportAudio(_ id: String, format: String) async throws -> URL {
        guard storageReady, exportingID == nil, !uploadLocked(id), !(recording && active == id),
              let index = clips.firstIndex(where: { $0.id == id && !$0.deleted }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        exportingID = id
        defer { exportingID = nil }
        reconcile(index)
        let clip = clips[index]
        guard clip.unavailableParts?.isEmpty != false, !clip.parts.isEmpty else { throw URLError(.cannotDecodeRawData) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let safeTitle = String(clip.title.map { "/\\:".contains($0) || $0.isNewline ? "_" : $0 }.prefix(60))
        let output = folder.appendingPathComponent(safeTitle.isEmpty ? "録音" : safeTitle).appendingPathExtension(format)
        do {
            try await RecordingFiles.exportAudio(clip.parts.map { root.appendingPathComponent($0) }, to: output)
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func permanentlyDelete(_ clip: Clip) {
        guard storageReady, clip.deleted, !uploadLocked(clip.id), !(recording && active == clip.id) else { return }
        if playingID == clip.id { stopPlayback() }
        do {
            try RecordingCatalog.permanentlyDelete(clip, from: clips, root: root)
            clips.removeAll { $0.id == clip.id }
            save()
        } catch { self.error = "完全削除に失敗しました。もう一度お試しください。\n\(voiceErrorDescription(error))" }
    }
    func uploadLocked(_ id: String) -> Bool { isBusy(id) || clips.contains { $0.id == id && ["ready", "sending"].contains($0.phase ?? "") } }
    func setSTT(_ id: String, _ value: String) { if !uploadLocked(id), let i = clips.firstIndex(where: { $0.id == id }) { clips[i].stt = value; save() } }
    func trash(_ clip: Clip) {
        if clip.deleted {
            do {
                guard try !RecordingCatalog.deletionStarted(clip.id, root: root) else {
                    error = "完全削除を開始した録音です。「完全に削除」から再試行してください。"
                    return
                }
            } catch { self.error = voiceErrorDescription(error); return }
        }
        guard !(recording && active == clip.id), !uploadLocked(clip.id) else { return }
        if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i].deleted.toggle(); save() }
    }
    func preparePlayback(_ clip: Clip) {
        guard !recording else { return }
        if playingID == clip.id { return }
        if preview { playingID = clip.id; playDuration = clip.duration; playTime = 0; return }
        stopPlayback()
        playbackURLs = clip.parts.map { root.appendingPathComponent($0) }.filter { RecordingFiles.duration($0) > 0 }
        timeline = PlaybackTimeline(durations: playbackURLs.map { RecordingFiles.duration($0) })
        playingID = clip.id; playDuration = timeline.duration; playTime = 0
    }
    func play(_ clip: Clip) {
        guard !recording else { return }
        preparePlayback(clip)
        if isPlaying { player?.pause(); isPlaying = false; return }
        if playTime >= playDuration { playTime = 0 }
        seek(playTime, start: true)
    }
    func stopPlayback() {
        player?.stop(); player = nil; isPlaying = false; playingID = nil
        playbackTimer?.invalidate(); playbackURLs = []; playTime = 0; playDuration = 0
    }
    func skip(_ seconds: Double) { seek(playTime + seconds, start: isPlaying) }
    func seek(_ seconds: Double, start: Bool? = nil) {
        guard !recording, !playbackURLs.isEmpty else { return }
        let run = start ?? isPlaying
        let target = min(max(0, seconds), playDuration)
        let position = timeline.position(target)
        do {
            player?.stop()
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: playbackURLs[position.index])
            playbackIndex = position.index; player?.delegate = self; player?.currentTime = position.offset
            playTime = target; isPlaying = run && target < playDuration
            if isPlaying, player?.play() != true { throw NSError(domain: "VoiceAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "音声を再生できませんでした"]) }
            playbackTimer?.invalidate()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in
                guard let self, self.isPlaying, let player = self.player else { return }
                self.playTime = min(self.playDuration, self.timeline.global(self.playbackIndex, player.currentTime))
            } }
        } catch { self.error = error.localizedDescription; isPlaying = false }
    }
    func becameActive() {
        guard !preview else { return }
        if recording, capture?.isRunning != true { pause(); error = "録音が中断されました。同じ録音から再開できます。" }
    }
    @objc nonisolated func interrupted(_ n: Notification) {
        guard let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, v == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor in
            guard self.recording else { return }
            self.pause(); self.error = "着信などで録音を一時停止しました。「再開」から続けられます。"
        }
    }
    @objc nonisolated func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        Task { @MainActor in
            guard self.recording else { return }
            self.pause(); self.error = "マイクの接続が変わったため一時停止しました。再開できます。"
        }
    }
}
extension Store: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            guard flag else { self.isPlaying = false; self.error = "録音の再生が中断されました。"; self.playbackTimer?.invalidate(); return }
            let next = self.playbackIndex + 1
            if next < self.playbackURLs.count { self.seek(self.timeline.global(next, 0), start: true) }
            else { self.isPlaying = false; self.playTime = self.playDuration; self.playbackTimer?.invalidate() }
        }
    }
}

@main struct VoiceMobileApp: App {
    @StateObject var store = VoiceMobileApp.makeStore()
    @MainActor static func makeStore() -> Store {
        let temporary = FileManager.default.temporaryDirectory
        let oldExports = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        for folder in oldExports where folder.lastPathComponent.hasPrefix("voice-export-") {
            let suffix = String(folder.lastPathComponent.dropFirst("voice-export-".count))
            if UUID(uuidString: suffix) != nil { try? FileManager.default.removeItem(at: folder) }
        }
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--ui-test-server"), args.indices.contains(index + 1),
           let caseIndex = args.firstIndex(of: "--ui-test-case"), args.indices.contains(caseIndex + 1),
           UUID(uuidString: args[caseIndex + 1]) != nil,
           let url = URL(string: args[index + 1]), url.scheme == "https", url.host == "localhost" {
            UIView.setAnimationsEnabled(false)
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UITestRecordings").appendingPathComponent(args[caseIndex + 1])
            let store = Store(directory: root)
            store.server = url.absoluteString; store.backend = "local"; store.sttBackend = "local"
            store.requestPermission = { true }
            store.recorderFactory = { let capture = Capture(); capture.fixtureMode = true; return capture }
            return store
        }
        #endif
        return Store()
    }
    var body: some Scene { WindowGroup { Library().environmentObject(store).preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil).environment(\.locale, Locale(identifier: "ja_JP")) } }
}
struct Library: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) var scenePhase
    @State var search = ""
    @State var selected: String?
    @State var source = 0
    @State var settings = false
    @State var newRecording = false
    @State var searching = false
    @State var renameID: String?
    @State var renameTitle = ""
    @State private var deletion: Clip?
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                if !store.connectionMessage.isEmpty { Text(store.connectionMessage).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("connection.message") }
                Text(source == 1 ? "\(store.jobs.count)件の録音" : "\(store.clips.filter { $0.deleted == (source == 2) }.count)件の録音").font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden)
                if source != 1 {
                    ForEach(store.clips.filter { $0.deleted == (source == 2) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { clip in
                        NavigationLink(value: clip.id) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(clip.title).font(.headline).lineLimit(1)
                                HStack { Text(clip.date, style: .date); Image(systemName: clip.isDraft ? "pause.circle" : "text.bubble"); Spacer(); Text(timeText(store.active == clip.id && store.recording ? store.seconds : clip.duration)).lineLimit(1).monospacedDigit() }.font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }.contextMenu {
                            if clip.deleted {
                                Button("完全に削除", systemImage: "trash.slash", role: .destructive) { deletion = clip }.disabled(store.uploadLocked(clip.id))
                            }
                            Button("名称変更", systemImage: "pencil") { renameID = clip.id; renameTitle = clip.title }
                            Button("文字起こしを表示", systemImage: "text.bubble") { selected = clip.id }
                            Button("完了して送信", systemImage: "arrow.up.circle") { store.finish(clip.id) }
                            Button(clip.deleted ? "復元" : "削除", systemImage: clip.deleted ? "arrow.uturn.backward" : "trash", role: clip.deleted ? nil : .destructive) { store.trash(clip) }
                        }.swipeActions(edge: .trailing, allowsFullSwipe: !clip.deleted) {
                            if clip.deleted {
                                Button("完全に削除", systemImage: "trash.slash") { deletion = clip }.tint(.red).disabled(store.uploadLocked(clip.id))
                            }
                            Button { store.trash(clip) } label: { Label(clip.deleted ? "復元" : "削除", systemImage: clip.deleted ? "arrow.uturn.backward" : "trash") }.tint(clip.deleted ? .blue : .red).disabled(store.recording && store.active == clip.id)
                        }
                    }
                } else {
                    ForEach(store.jobs.filter { search.isEmpty || $0.original_name.localizedCaseInsensitiveContains(search) }) { job in
                        NavigationLink(value: job.id) { VStack(alignment: .leading, spacing: 6) { Text(job.original_name).font(.headline); Text("\(job.status) · \(job.progress)").font(.caption).foregroundStyle(.secondary).lineLimit(2) } }
                    }
                }
            }.listStyle(.plain).navigationTitle(source == 2 ? "最近削除した項目" : "すべての録音")
                .searchable(text: $search, isPresented: $searching, prompt: "タイトルを検索")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Menu {
                        Picker("録音一覧", selection: $source) { Text("この端末").tag(0); Text("サーバーの録音").tag(1); Text("最近削除した項目").tag(2) }; Button("設定") { settings = true }
                    } label: { Image(systemName: "sidebar.left") }.accessibilityIdentifier("library.menu") }
                    ToolbarItemGroup(placement: .topBarTrailing) { EditButton(); Button { searching.toggle() } label: { Image(systemName: "magnifyingglass") } }
                }
                .refreshable { await store.refresh() }
                .safeAreaInset(edge: .bottom) {
                    Group {
                        if store.recording, let id = store.active {
                            VStack(spacing: 12) {
                                Button { selected = id; searching = false } label: { Label("録音画面を開く  \(timeText(store.seconds))", systemImage: "waveform").lineLimit(1).monospacedDigit() }.accessibilityIdentifier("library.open-recording")
                                RecordingControls(id: id)
                            }.padding(12).frame(maxWidth: .infinity).background(.bar)
                        } else {
                            Button { searching = false; newRecording = true } label: { Circle().fill(.red).frame(width: 58, height: 58).padding(8).glassEffect(.regular.interactive(), in: Circle()) }.buttonStyle(.plain).accessibilityLabel("新規録音").accessibilityIdentifier("library.new-recording").padding(12)
                        }
                    }
                }
        } detail: {
            if let clip = store.clips.first(where: { $0.id == selected }) { ClipView(id: clip.id).id(clip.id) }
            else if let job = store.jobs.first(where: { $0.id == selected }) { Results(jobIDs: [job.id], title: job.original_name).id(job.id) }
            else { ContentUnavailableView("録音を選択", systemImage: "waveform", description: Text("文字起こしと要約を表示します")) }
        }
        .sheet(isPresented: $settings) { Settings() }.sheet(isPresented: $newRecording) { NewRecording() }
        .onChange(of: store.needsServerSettings) {
            if store.needsServerSettings { settings = true; store.needsServerSettings = false }
        }
        .confirmationDialog("この録音を端末から完全に削除しますか？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible, presenting: deletion) { clip in
            Button("完全に削除", role: .destructive) { store.permanentlyDelete(clip); deletion = nil }
            Button("キャンセル", role: .cancel) { deletion = nil }
        } message: { clip in Text(clip.title) }
        .alert("名称変更", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("録音名", text: $renameTitle)
            Button("保存") { if let id = renameID { store.rename(id, renameTitle) }; renameID = nil }
            Button("キャンセル", role: .cancel) { renameID = nil }
        }
        .task {
            if store.preview {
                if ProcessInfo.processInfo.arguments.contains("--ui-detail") || ProcessInfo.processInfo.arguments.contains("--ui-recording") { selected = store.clips.first?.id }
            } else { store.resumePending(); await store.refresh() }
        }
        .onChange(of: store.active) { selected = $0 }
        .onChange(of: scenePhase) { if $0 == .active { store.becameActive() } }
        .alert("お知らせ", isPresented: Binding(get: { !store.error.isEmpty }, set: { if !$0 { store.error = "" } })) { Button("コピー") { UIPasteboard.general.string = store.error }; Button("OK") { store.error = "" } } message: { Text(store.error) }
    }
}

struct RecordingControls: View {
    @EnvironmentObject var store: Store
    let id: String
    var body: some View {
        HStack(spacing: 16) {
            Button { store.pause() } label: { Label("一時停止", systemImage: "pause.fill").lineLimit(1) }.buttonStyle(.glass).accessibilityIdentifier("recording.pause")
            Button { store.finish(id) } label: { Label("停止して送信", systemImage: "stop.fill").lineLimit(1) }.buttonStyle(.glassProminent).tint(.red).accessibilityIdentifier("recording.finish")
        }.font(.subheadline).frame(maxWidth: .infinity)
    }
}
struct Waveform: View {
    let levels: [Float]
    var body: some View { GeometryReader { geo in HStack(spacing: 2) { ForEach(Array(levels.enumerated()), id: \.offset) { _, level in Capsule().fill(Color.red).frame(width: max(1, geo.size.width / CGFloat(max(1, levels.count)) - 2), height: max(2, CGFloat(level) * geo.size.height)) } }.frame(height: geo.size.height).clipped() } }
}
struct NewRecording: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var title = ""
    var body: some View { NavigationStack { Form {
        TextField("録音の名前", text: $title).accessibilityIdentifier("recording.title")
        STTPicker(value: $store.sttBackend)
        Text("録音中は端末へバックアップします。「停止して送信」を押した後で、全体をまとめて送信します。").font(.footnote).foregroundStyle(.secondary)
        Button("録音開始") { Task { await store.begin(title); if store.recording { dismiss() } } }.foregroundStyle(.red)
    }.navigationTitle("新規録音").toolbar { Button("閉じる") { dismiss() } } } }
}
struct STTPicker: View {
    @Binding var value: String
    var body: some View { Picker("文字起こしエンジン", selection: $value) { Text("ローカルGPU · large-v3-turbo").tag("local"); Text("さくら · whisper-large-v3-turbo").tag("sakura") } }
}
struct ClipView: View {
    @EnvironmentObject var store: Store
    let id: String
    @State var rename = false
    @State var name = ""
    @State private var choosingExport = false
    @State private var exportFile: ExportFile?
    @State private var cleanupFolder: URL?
    @State private var exportTask: Task<Void, Never>?

    private func exportAudio(_ format: String) {
        exportTask = Task {
            do {
                let url = try await store.exportAudio(id, format: format)
                cleanupFolder = url.deletingLastPathComponent()
                exportFile = ExportFile(url: url)
            } catch {
                if !Task.isCancelled { store.error = "音声を書き出せませんでした。\n\(voiceErrorDescription(error))" }
            }
        }
    }
    var body: some View {
        if let clip = store.clips.first(where: { $0.id == id }) {
            let active = store.active == id && store.recording
            VStack(spacing: 0) {
                if active {
                    VStack(spacing: 24) {
                        Label("録音中", systemImage: "record.circle.fill").foregroundStyle(.red)
                        Text(timeText(store.seconds)).font(.system(size: 46, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.5).fixedSize(horizontal: true, vertical: false).accessibilityIdentifier("recording.time")
                        Waveform(levels: store.levels).frame(height: 100)
                        Text("端末へバックアップ中\n送信は録音完了後に行います").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Spacer()
                        RecordingControls(id: id)
                    }.padding(24)
                } else if clip.isDraft && clip.finalJob == nil {
                    VStack(spacing: 24) {
                        Image(systemName: "pause.circle").font(.system(size: 50)).foregroundStyle(.secondary)
                        Text(timeText(clip.duration)).font(.largeTitle.monospacedDigit()).lineLimit(1).fixedSize()
                        Text("録音は端末に保存されています").foregroundStyle(.secondary)
                        STTPicker(value: Binding(get: { clip.stt ?? store.sttBackend }, set: { store.setSTT(id, $0) }))
                        HStack { Button("録音を再開") { Task { await store.resume(id) } }.buttonStyle(.glass).accessibilityIdentifier("recording.resume"); Button("完了して送信") { store.finish(id) }.buttonStyle(.glassProminent).tint(.red).accessibilityIdentifier("recording.send") }.disabled(store.recording || store.uploadLocked(id))
                        Spacer()
                    }.padding(24)
                } else {
                    Results(jobIDs: clip.jobIDs, title: clip.title)
                }
                if store.sendingID == id { HStack { ProgressView(); Text(store.sendStatus).font(.caption) }.padding() }
                if store.exportingID == id { ProgressView("音声を書き出しています…").padding() }
                if !active { playback(clip) }
            }.navigationTitle(clip.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu {
                    if !clip.deleted {
                        Button("音声を書き出す", systemImage: "square.and.arrow.up") { choosingExport = true }
                            .disabled(store.uploadLocked(id) || store.exportingID != nil || active || clip.parts.isEmpty)
                    }
                    Button("名称変更") { name = clip.title; rename = true }
                    Button("録音を再開") { Task { await store.resume(id) } }.disabled(store.recording || store.sendingID == id)
                    STTPicker(value: Binding(get: { clip.stt ?? store.sttBackend }, set: { store.setSTT(id, $0) }))
                    Button("完了して送信・再送") { store.finish(id) }.disabled(store.recording || store.sendingID == id)
                    Button(clip.deleted ? "復元" : "削除") { store.trash(clip) }
                } label: { Image(systemName: "ellipsis.circle") } } }
                .alert("名称変更", isPresented: $rename) { TextField("録音名", text: $name); Button("保存") { store.rename(id, name) }; Button("キャンセル", role: .cancel) {} }
                .task(id: id) { if !store.recording { store.preparePlayback(clip) } }
                .onDisappear { exportTask?.cancel() }
                .confirmationDialog("書き出し形式", isPresented: $choosingExport, titleVisibility: .visible) {
                    Button("WAV") { exportAudio("wav") }
                    Button("M4A") { exportAudio("m4a") }
                }
                .sheet(item: $exportFile, onDismiss: {
                    if let cleanupFolder { try? FileManager.default.removeItem(at: cleanupFolder) }
                    cleanupFolder = nil
                }) { file in AudioShareSheet(url: file.url) }
                .onChange(of: store.recording) { if !$0 { store.preparePlayback(clip) } }
        }
    }
    func playback(_ clip: Clip) -> some View {
        let duration = store.playingID == id ? store.playDuration : clip.duration
        let current = store.playingID == id ? store.playTime : 0
        let sliderEnd = max(0.001, duration)
        return VStack(spacing: 10) {
            Slider(value: Binding(get: { min(current, sliderEnd) }, set: { store.preparePlayback(clip); store.seek($0) }), in: 0...sliderEnd).tint(.primary).disabled(store.recording || duration == 0).accessibilityIdentifier("playback.seek").accessibilityValue("\(timeText(current)) / \(timeText(duration))")
            HStack { Text(timeText(current)).accessibilityIdentifier("playback.elapsed"); Spacer(); Text("-" + timeText(max(0, duration - current))) }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 28) {
                Button { store.preparePlayback(clip); store.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Button { store.play(clip) } label: { Image(systemName: store.isPlaying && store.playingID == id ? "pause.fill" : "play.fill").font(.largeTitle) }.accessibilityIdentifier("playback.play").accessibilityValue(store.isPlaying && store.playingID == id ? "再生中" : "停止中")
                Button { store.preparePlayback(clip); store.skip(15) } label: { Image(systemName: "goforward.15").font(.title2) }
                Spacer(minLength: 8)
                Text(timeText(duration)).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).fixedSize(horizontal: true, vertical: false).accessibilityIdentifier("playback.duration")
            }.tint(.primary).disabled(store.recording)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct AudioShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ReadableText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.accessibilityIdentifier = "result.text"
        view.isEditable = false; view.isSelectable = true; view.alwaysBounceVertical = true
        view.backgroundColor = .clear; view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view.adjustsFontForContentSizeCategory = true
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        view.font = UIFont.preferredFont(forTextStyle: .body); view.textColor = .label
        if view.text != text { view.text = text }
    }
}

struct Results: View {
    @EnvironmentObject var store: Store
    let jobIDs: [String]
    let title: String
    @State var entries: [(String, Artifact)] = []
    @State var content = ""
    @State var failure = ""
    @State var kind = "original"
    @State var busy = false
    @State var progress = ""
    @State var cache: [String: String] = [:]
    @State var copied = false
    var body: some View {
        VStack(spacing: 0) {
            if !failure.isEmpty { Text(failure).font(.footnote).foregroundStyle(.red).padding(8) }
            if !progress.isEmpty { Text(progress).font(.caption).foregroundStyle(.secondary).padding(8) }
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(jobIDs.isEmpty ? "まだ送信していません" : "成果物を確認中", systemImage: "text.bubble",
                    description: Text(jobIDs.isEmpty ? "録音を完了して送信すると、ここに文字起こしを表示します。" : "処理状態は自動で更新します。"))
            } else {
                ReadableText(text: content).id(jobIDs.joined() + kind).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Menu {
                    Button("丁寧にする") { Task { await generate("polish", "brief") } }
                    Button("3行程度に要約") { Task { await generate("summary", "brief") } }
                    Button("詳しく要約") { Task { await generate("summary", "detailed") } }
                } label: { Label("作成", systemImage: "sparkles") }.disabled(busy || entries.allSatisfy { $0.1.kind != "original" }).accessibilityIdentifier("result.generate")
                Spacer()
                if busy { ProgressView() }
                Button { UIPasteboard.general.string = content; copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.disabled(content.isEmpty).accessibilityLabel("文字起こしをコピー").accessibilityIdentifier("result.copy").accessibilityValue(copied ? "コピー済み" : "")
                Button { cache = [:]; Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                if !content.isEmpty { ShareLink(item: content) { Image(systemName: "square.and.arrow.up") } }
            }.padding()
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu {
                Picker("表示", selection: $kind) { Text("文字起こし").tag("original"); Text("丁寧化").tag("polished"); Text("3行要約").tag("brief"); Text("詳しい要約").tag("detailed") }
            } label: { Image(systemName: "text.bubble").symbolVariant(.fill) }.accessibilityIdentifier("result.mode") } }
            .onChange(of: kind) { copied = false; content = ""; progress = "" }
            .task(id: jobIDs.joined() + kind) {
                while !Task.isCancelled {
                    await reload()
                    do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { break }
                }
            }
    }
    func reload() async {
        let selection = kind
        if store.preview {
            content = Array(repeating: "文字起こしの本文です。長い録音の結果もスクロールして読めます。選択してコピーするか、下のコピーボタンから全文をコピーできます。", count: 100).joined(separator: "\n\n")
            return
        }
        let result = await ArtifactReading.load(jobIDs, kind: selection, store: store)
        guard !Task.isCancelled, selection == kind else { return }
        entries = result.entries; content = result.text; failure = result.failure
        progress = result.progress
    }
    func generate(_ action: String, _ mode: String) async {
        busy = true; defer { busy = false }
        do {
            let originals = entries.filter { $0.1.kind == "original" }
            let combined = originals.filter { $0.1.name.hasSuffix("_統合.md") }
            for (id, file) in combined.isEmpty ? originals : combined { try await store.generate(id, file.name, action, mode) }
            cache = [:]; kind = action == "polish" ? "polished" : mode
            progress = "受付済み。完成すると自動表示します。"
        } catch { failure = error.localizedDescription }
    }
}
struct Settings: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View { NavigationStack { Form {
        Section("サーバー") { TextField("HTTPS URL（/voiceまで）", text: $store.server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL); Text("同じTailscaleへ接続してください").font(.footnote); Button("接続確認") { Task { await store.refresh(showError: true) } } }
        STTPicker(value: $store.sttBackend)
        Picker("丁寧化・要約エンジン", selection: $store.backend) { Text("ローカルLLM").tag("local"); Text("Sakura AI Engine").tag("sakura") }
        Text("さくら文字起こしを選ぶと、録音完了後の音声をサーバー経由でさくらのAI Engineへ送信します。").font(.footnote)
        Picker("外観", selection: $store.appearance) { Text("端末に合わせる").tag("system"); Text("ライト").tag("light"); Text("ダーク").tag("dark") }
        LabeledContent("バージョン", value: voiceAppVersion)
    }.navigationTitle("設定").toolbar { Button("完了") { dismiss() } } } }
}
