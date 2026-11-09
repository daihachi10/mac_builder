import AVFoundation

#if DEBUG || !os(iOS)
enum AudioFormatChecks {
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for rate: Double in [16000, 44100, 48000] {
            for channels: AVAudioChannelCount in [1, 2] {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                buffer.frameLength = 1024
                for c in 0..<Int(channels) { for i in 0..<1024 { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.1) * 0.25) } }
                let url = folder.appendingPathComponent("\(Int(rate))-\(channels).wav")
                var file: AVAudioFile? = try AudioFileWriter.open(url, input: format)
                try file!.write(from: buffer)
                file = nil
                let read = try AVAudioFile(forReading: url)
                guard read.length == 1024, read.fileFormat.sampleRate == rate, read.fileFormat.channelCount == channels else { fatalError("PCM regression: \(url.lastPathComponent)") }
                print("PASS \(Int(rate))Hz / \(channels)ch")
            }
        }
        let timeline = PlaybackTimeline(durations: [5, 5, 3])
        guard timeline.duration == 13, timeline.position(8).index == 1,
              timeline.position(8).offset == 3, timeline.global(2, 2) == 12,
              timeline.position(13).index == 2, timeText(225) == "03:45",
              timeText(5400) == "1:30:00" else { fatalError("Full recording timeline regression") }
        print("PASS global playback and single-line time values")
        let old = Data("{\"id\":\"old\",\"title\":\"old\",\"date\":0,\"duration\":13,\"parts\":[\"a.wav\"],\"jobs\":{\"a.wav\":\"job1\"},\"deleted\":false}".utf8)
        let clip = try JSONDecoder().decode(Clip.self, from: old)
        guard clip.jobIDs == ["job1"], clip.parts == ["a.wav"] else { fatalError("Catalog migration regression") }
        var relative = clip
        relative.parts = ["folder/a.wav", "folder/a.wav"]
        guard relative.jobIDs == ["job1"] else { fatalError("Legacy filename job association regression") }
        print("PASS previous catalog compatibility")
        let source = folder.appendingPathComponent("16000-1.wav")
        var damaged = try Data(contentsOf: source)
        guard let range = damaged.range(of: Data("data".utf8)) else { fatalError("Missing WAV header") }
        damaged.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        damaged.replaceSubrange(range.upperBound..<range.upperBound + 4, with: [0, 0, 0, 0])
        let broken = folder.appendingPathComponent("interrupted.wav")
        try damaged.write(to: broken)
        guard let recovered = RecordingFiles.recover(broken), RecordingFiles.duration(recovered) > 0,
              try Data(contentsOf: broken) == damaged else { fatalError("Interrupted recording recovery regression") }
        print("PASS interrupted WAV recovery preserves original")
        let fromUnclosed = folder.appendingPathComponent("from-unclosed.wav")
        try await RecordingFiles.export([broken], to: fromUnclosed)
        let reopened = try AVAudioFile(forReading: fromUnclosed)
        guard reopened.length == 1024, try Data(contentsOf: broken) == damaged else { fatalError("Direct PCM recovery lost the first segment") }
        print("PASS an unclosed first WAV segment can be uploaded without Core Audio decoding")
        let merged = folder.appendingPathComponent("merged.wav")
        let parts = [folder.appendingPathComponent("16000-1.wav"), folder.appendingPathComponent("44100-1.wav"), folder.appendingPathComponent("48000-2.wav")]
        let expected = parts.reduce(0) { $0 + RecordingFiles.duration($1) }
        try await RecordingFiles.export(parts, to: merged)
        guard abs(RecordingFiles.duration(merged) - expected) < 0.01 else { fatalError("Whole recording export duration regression") }
        let normalized = try AVAudioFile(forReading: merged)
        guard normalized.fileFormat.sampleRate == 16000, normalized.fileFormat.channelCount == 1,
              normalized.fileFormat.commonFormat == .pcmFormatInt16 else { fatalError("Upload must be 16kHz mono PCM16 WAV") }
        print("PASS single upload file combines all backup segments")

        // An extensible stereo header and an odd-sized ancillary chunk occur
        // in WAVs from different devices. Use independent literal bytes.
        let extensible = folder.appendingPathComponent("extensible.wav")
        var packet = Data([
            0x52,0x49,0x46,0x46, 84,0,0,0, 0x57,0x41,0x56,0x45,
            0x4a,0x55,0x4e,0x4b, 1,0,0,0, 0x5a,0,
            0x66,0x6d,0x74,0x20, 40,0,0,0, 0xfe,0xff,2,0,
            0x80,0xbb,0,0, 0x00,0xee,0x02,0, 4,0,16,0,
            22,0,16,0, 3,0,0,0,
            1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113,
            0x64,0x61,0x74,0x61, 12,0,0,0
        ])
        for _ in 0..<3 { packet.append(contentsOf: [0x00,0x20,0x00,0x10]) }
        packet[4] = UInt8(packet.count - 8)
        try packet.write(to: extensible)
        let extensibleOut = folder.appendingPathComponent("extensible-normalized.wav")
        try await RecordingFiles.export([extensible], to: extensibleOut)
        let payload = try Data(contentsOf: extensibleOut)
        guard payload.count == 46, Array(payload.suffix(2)) == [0x00,0x18] else { fatalError("Extensible stereo WAV did not downmix to the expected sample") }
        print("PASS WAV extensible stereo, ancillary chunk padding, exact 48 kHz to 16 kHz conversion")
        let long = folder.appendingPathComponent("long.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        samples.frameLength = 4096
        for channel in 0..<2 { for frame in 0..<4096 { samples.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.1) * 0.25) } }
        var writer: AVAudioFile? = try AudioFileWriter.open(long, input: format)
        for _ in 0..<100 { try writer!.write(from: samples) }
        writer = nil
        let many = Array(repeating: parts, count: 40).flatMap { $0 } + [long]
        let longOutput = folder.appendingPathComponent("many.wav")
        let originals = try parts.map { try Data(contentsOf: $0) }
        try await RecordingFiles.export(many, to: longOutput)
        let expectedLong = many.reduce(0) { $0 + RecordingFiles.duration($1) }
        guard abs(RecordingFiles.duration(longOutput) - expectedLong) < 0.05 else { fatalError("Dropped/duplicated buffers in streaming merge") }
        guard try parts.map({ try Data(contentsOf: $0) }) == originals else { fatalError("Original recordings changed") }
        let read = try AVAudioFile(forReading: longOutput, commonFormat: .pcmFormatFloat32, interleaved: false)
        let data = AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: 2048)!
        try read.read(into: data)
        guard (0..<Int(data.frameLength)).contains(where: { abs(data.floatChannelData![0][$0]) > 0.05 }) else { fatalError("Merged recording is silent") }
        print("PASS 121 fragments, resampling, stereo downmix and preserved source files")
        let compact = folder.appendingPathComponent("many.m4a")
        try await RecordingFiles.exportAudio(many, to: compact)
        guard abs(RecordingFiles.duration(compact) - expectedLong) < 0.15 else { fatalError("M4A duration mismatch") }
        print("PASS multi-segment M4A export")
        let missing = folder.appendingPathComponent("missing.wav")
        do { try await RecordingFiles.export([missing], to: folder.appendingPathComponent("failed.wav")); fatalError("Missing audio should fail") }
        catch { guard voiceErrorDescription(error).contains("VoiceAudio (2)") else { fatalError("Missing diagnostics") } }
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("failed.wav").path) else { fatalError("Partial export was promoted") }
        print("PASS failed preparation keeps diagnostics and never uploads a partial file")
    }
}
#if !os(iOS)
@main struct AudioFormatSmoke {
    static func main() async throws {
        try await AudioFormatChecks.run()
        try verifyPermanentDeletion()
        try await verifySpeechGain()
        if CommandLine.arguments.contains("--long") { try await verifyNinetyMinutes() }
    }

    static func verifySpeechGain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("quiet.wav")
        let output = folder.appendingPathComponent("enhanced.wav")
        let writer = try WavePCM.Writer(input)
        let quiet = (0..<16000).map { Int16(sin(Double($0) * 0.2) * 160) }
        let loud = (0..<16000).map { Int16(sin(Double($0) * 0.2) * 31000) }
        try writer.write(quiet + loud + Array(repeating: 0, count: 16000))
        try writer.finish()
        try await RecordingFiles.exportAudio([input], to: output)
        let file = try AVAudioFile(forReading: output)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000)!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        func peak(_ range: Range<Int>) -> Float { range.map { abs(samples[$0]) }.max() ?? 0 }
        guard buffer.frameLength == 48000, peak(8000..<16000) > 0.05,
              peak(16000..<32000) < 0.9, peak(40000..<48000) == 0 else {
            fatalError("Speech gain did not raise quiet audio, limit loud peaks, and preserve silence")
        }
        print("PASS quiet speech gain, peak limit and silent tail")
    }

    static func verifyPermanentDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var clip = Clip(title: "Synthetic recording")
        try RecordingCatalog.save([clip], to: root)
        do {
            try RecordingCatalog.permanentlyDelete(clip, from: [clip], root: root)
            fatalError("Active recording was eligible for permanent deletion")
        } catch {}
        clip.deleted = true
        let other = Clip(title: "Other synthetic recording")
        try RecordingCatalog.save([clip, other], to: root)
        let folder = root.appendingPathComponent(clip.id)
        let audio = folder.appendingPathComponent("export-pcm-v2-0.wav")
        try Data(repeating: 1, count: 1024 * 1024).write(to: audio)
        try RecordingCatalog.permanentlyDelete(clip, from: [clip, other], root: root)
        guard !FileManager.default.fileExists(atPath: folder.path),
              try RecordingCatalog.load(root).clips.map(\.id) == [other.id] else {
            fatalError("Deleted audio or catalog entry survived")
        }
        try FileManager.default.copyItem(at: root.appendingPathComponent("catalog.json"), to: root.appendingPathComponent("test-stale.json"))
        try Data("invalid".utf8).write(to: root.appendingPathComponent("catalog.json"))
        guard try !RecordingCatalog.load(root).clips.contains(where: { $0.id == clip.id }) else {
            fatalError("Deleted recording recovered from backup")
        }
        print("PASS permanent deletion removes owned files and filters stale catalogs")
    }

    static func verifyNinetyMinutes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("ten-seconds.wav")
        let output = folder.appendingPathComponent("ninety-minutes.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000)!
        samples.frameLength = samples.frameCapacity
        for index in 0..<Int(samples.frameLength) { samples.floatChannelData![0][index] = Float(sin(Double(index) * 0.04) * 0.2) }
        do {
            let writer = try AudioFileWriter.open(source, input: format)
            try writer.write(from: samples)
        }
        let started = Date()
        try await RecordingFiles.export(Array(repeating: source, count: 540), to: output)
        let normalized = try AVAudioFile(forReading: output)
        guard normalized.length == 86400000, normalized.fileFormat.sampleRate == 16000 else { fatalError("90-minute PCM output frame count is wrong") }
        print("PASS 90 minutes / 540 segments in \(Date().timeIntervalSince(started)) seconds, 86400000 frames")
        let compact = folder.appendingPathComponent("ninety-minutes.m4a")
        try await RecordingFiles.exportAudio([output], to: compact)
        guard abs(RecordingFiles.duration(compact) - 5400) < 0.2 else { fatalError("90-minute M4A duration mismatch") }
        let wavBytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let m4aBytes = try compact.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard m4aBytes > 0, m4aBytes < wavBytes * 2 / 3 else { fatalError("M4A did not sufficiently reduce upload size") }
        print("PASS 90-minute M4A export: \(m4aBytes) bytes vs \(wavBytes) WAV bytes")
    }
}
#endif
#endif
