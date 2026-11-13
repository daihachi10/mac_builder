import Foundation
import AVFoundation

struct ArchivedRecording: Codable {
    let url: URL
    let sha256: String
    let bytes: Int64
}

struct Clip: Codable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var date = Date()
    var duration: Double = 0
    var parts: [String] = []
    var jobs: [String: String] = [:]
    var deleted = false
    // Optional fields preserve catalogs written by older app versions.
    var phase: String? = "paused"
    var revision: Int? = 0
    var stt: String? = "local"
    var finalJob: String?
    var unavailableParts: [String]?
    var archivedRecording: ArchivedRecording?
    var pendingAudioRemoval: [String]?
    var jobIDs: [String] {
        if let finalJob { return [finalJob] }
        let matched = parts.compactMap { part in
            jobs[part] ?? jobs[URL(fileURLWithPath: part).lastPathComponent]
                ?? jobs[part.replacingOccurrences(of: ".recovered.wav", with: ".wav")]
                ?? jobs[URL(fileURLWithPath: part).lastPathComponent.replacingOccurrences(of: ".recovered.wav", with: ".wav")]
        }
        let values = matched.isEmpty ? jobs.keys.sorted().compactMap { jobs[$0] } : matched
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    var isDraft: Bool { archivedRecording == nil && (phase == "paused" || phase == "recording") }
}

func timeText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value % 3600 / 60, value % 60)
        : String(format: "%02d:%02d", value / 60, value % 60)
}

struct PlaybackTimeline {
    let durations: [Double]
    var duration: Double { durations.reduce(0, +) }
    func position(_ seconds: Double) -> (index: Int, offset: Double) {
        var remaining = max(0, min(duration, seconds))
        for (index, length) in durations.enumerated() {
            if remaining < length || index == durations.count - 1 { return (index, min(length, remaining)) }
            remaining -= length
        }
        return (0, 0)
    }
    func global(_ index: Int, _ offset: Double) -> Double { durations.prefix(index).reduce(0, +) + offset }
}

func voiceErrorDescription(_ error: Error) -> String {
    var lines: [String] = []
    var current: NSError? = error as NSError
    for _ in 0..<4 {
        guard let value = current else { break }
        lines.append("\(value.domain) (\(value.code)): \(value.localizedDescription)")
        if let reason = value.localizedFailureReason, !reason.isEmpty { lines.append(reason) }
        current = value.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return lines.joined(separator: "\n")
}

enum RecordingFiles {
    static func exportAudio(_ parts: [URL], to output: URL, enhanceSpeech: Bool = true) async throws {
        if output.pathExtension == "wav" {
            try await export(parts, to: output, enhanceSpeech: enhanceSpeech)
            return
        }
        let wav = output.deletingLastPathComponent().appendingPathComponent("export-working-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await export(parts, to: wav, enhanceSpeech: enhanceSpeech)
        try Task.checkCancellation()
        let asset = AVURLAsset(url: wav)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { try await session.export(to: output, as: .m4a) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
    }
    static func duration(_ url: URL) -> Double {
        if let layout = try? WavePCM.inspect(url) { return layout.duration }
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
    // A killed process may leave a WAV with uncommitted RIFF/data lengths.
    // Repair a copy, preserving the original recording byte-for-byte.
    static func recover(_ url: URL) -> URL? {
        guard let layout = try? WavePCM.inspect(url) else { return duration(url) > 0 ? url : nil }
        guard layout.byteCount > 0 else { return nil }
        if layout.needsRepair { return (try? WavePCM.repairedCopy(of: url, layout: layout)) ?? url }
        return url
    }
    static func export(_ parts: [URL], to output: URL, enhanceSpeech: Bool = false) async throws {
        // PCM conversion runs away from the UI and never needs the AAC encoder.
        try await Task.detached(priority: .userInitiated) { try mergePCM(parts, to: output, enhanceSpeech: enhanceSpeech) }.value
    }
    private static func mergePCM(_ parts: [URL], to output: URL, enhanceSpeech: Bool) throws {
        guard !parts.isEmpty, output.pathExtension.lowercased() == "wav" else {
            throw NSError(domain: "VoiceAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "結合する録音、またはWAV保存先がありません"])
        }
        let staging = output.deletingPathExtension().appendingPathExtension("partial.wav")
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        do {
            let writer = try WavePCM.Writer(staging, enhanceSpeech: enhanceSpeech)
            for url in parts {
                do {
                    do { try WavePCM.append(url, to: writer) }
                    catch WavePCM.Failure.unsupported { try appendLegacyAudio(url, to: writer) }
                } catch {
                    throw NSError(domain: "VoiceAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "録音区間の読み込み・結合に失敗: \(url.lastPathComponent)", NSUnderlyingErrorKey: error])
                }
            }
            try writer.finish()
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try FileManager.default.moveItem(at: staging, to: output)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }

    // Older catalogs can still contain M4A or another compressed container.
    private static func appendLegacyAudio(_ url: URL, to writer: WavePCM.Writer) throws {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.length > 0 else { throw URLError(.zeroByteResource) }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(WavePCM.Writer.rate), channels: 1)!
        let capacity: AVAudioFrameCount = 32768
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity),
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw URLError(.cannotDecodeRawData) }
        let startingBytes = writer.byteCount
        while true {
            var readError: Error?
            var conversionError: NSError?
            converted.frameLength = 0
            let status = converter.convert(to: converted, error: &conversionError) { requested, state in
                guard input.framePosition < input.length, readError == nil else { state.pointee = .endOfStream; return nil }
                do {
                    try input.read(into: source, frameCount: min(capacity, max(1, requested)))
                    guard source.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return source
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if let channel = converted.floatChannelData?[0], converted.frameLength > 0 {
                try writer.write((0..<Int(converted.frameLength)).map { WavePCM.quantize(Double(channel[$0]) * 32768) })
            }
            if status == .endOfStream { break }
            guard status == .haveData, converted.frameLength > 0 else { throw URLError(.cannotDecodeRawData) }
        }
        guard writer.byteCount > startingBytes else { throw URLError(.zeroByteResource) }
    }
}
