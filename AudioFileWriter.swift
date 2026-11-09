import AVFoundation

enum AudioFileWriter {
    static func open(_ url: URL, input: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: input.sampleRate,
            AVNumberOfChannelsKey: input.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: input.commonFormat, interleaved: input.isInterleaved)
    }
}
