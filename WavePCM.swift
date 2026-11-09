import Foundation

/// Reads the bytes written by the recorder without opening a Core Audio decoder.
enum WavePCM {
    enum Failure: LocalizedError {
        case unsupported, damaged, empty, tooLarge

        var errorDescription: String? {
            switch self {
            case .unsupported: return "この音声はリニアPCMのWAVではありません"
            case .damaged: return "WAVのヘッダーまたは音声データを読み込めません"
            case .empty: return "WAVに読み出せる音声サンプルがありません"
            case .tooLarge: return "WAVの最大サイズを超えています"
            }
        }
    }

    struct Layout {
        let rate: Int
        let channels: Int
        let bits: Int
        let floating: Bool
        let dataOffset: UInt64
        let byteCount: UInt64
        let needsRepair: Bool

        var sampleBytes: Int { bits / 8 }
        var frameBytes: Int { channels * sampleBytes }
        var duration: Double { Double(byteCount / UInt64(frameBytes)) / Double(rate) }
    }

    static func inspect(_ url: URL) throws -> Layout {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try inspect(input)
    }

    private static func inspect(_ input: FileHandle) throws -> Layout {
        let size = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let header = try read(input, count: 12)
        guard tag(header, 0) == "RIFF", tag(header, 8) == "WAVE" else { throw Failure.unsupported }
        let riffLength = UInt64(u32(header, 4)) + 8
        var offset: UInt64 = 12
        var encoding: (rate: Int, channels: Int, bits: Int, floating: Bool)?
        while offset + 8 <= size {
            try input.seek(toOffset: offset)
            let chunk = try read(input, count: 8)
            let length = UInt64(u32(chunk, 4))
            let start = offset + 8
            switch tag(chunk, 0) {
            case "fmt ":
                guard length >= 16, start + length <= size else { throw Failure.damaged }
                let fmt = try read(input, count: Int(min(40, length)))
                var format = u16(fmt, 0)
                if format == 0xfffe {
                    // WAVE_FORMAT_EXTENSIBLE uses the same interleaved samples.
                    guard fmt.count == 40, u16(fmt, 16) >= 22,
                          Array(fmt[26..<40]) == [0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113] else { throw Failure.unsupported }
                    format = u16(fmt, 24)
                }
                let channels = Int(u16(fmt, 2))
                let rate = Int(u32(fmt, 4))
                let bits = Int(u16(fmt, 14))
                let validBits = format == 1 ? [8, 16, 24, 32].contains(bits) : format == 3 && bits == 32
                guard validBits, (1...32).contains(channels), (8000...192000).contains(rate),
                      Int(u16(fmt, 12)) == channels * (bits / 8) else { throw Failure.unsupported }
                encoding = (rate, channels, bits, format == 3)
            case "data":
                guard let encoding else { throw Failure.damaged }
                let available = size - start
                let frameBytes = UInt64(encoding.channels * (encoding.bits / 8))
                // A recording killed before close can have zero or stale lengths.
                // The recorder stores its sample data in the final chunk.
                let count = length == 0 ? available : min(available, length)
                let aligned = count - count % frameBytes
                let repair = length != aligned || riffLength < start + aligned || riffLength > size
                return Layout(rate: encoding.rate, channels: encoding.channels, bits: encoding.bits,
                              floating: encoding.floating, dataOffset: start, byteCount: aligned, needsRepair: repair)
            default: break
            }
            guard start + length <= size else { throw Failure.damaged }
            offset = start + length + length % 2
        }
        throw Failure.damaged
    }

    static func repairedCopy(of url: URL, layout: Layout) throws -> URL {
        guard layout.byteCount > 0 else { throw Failure.empty }
        let recovered = url.deletingPathExtension().appendingPathExtension("recovered.wav")
        if let previous = try? inspect(recovered), !previous.needsRepair,
           previous.byteCount == layout.byteCount, previous.rate == layout.rate { return recovered }
        let temporary = recovered.appendingPathExtension(UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: url, to: temporary)
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        let audioEnd = layout.dataOffset + layout.byteCount
        guard audioEnd <= UInt64(UInt32.max) else { throw Failure.tooLarge }
        try file.truncate(atOffset: audioEnd)
        try file.seek(toOffset: 4)
        try file.write(contentsOf: bytes(UInt32(audioEnd - 8)))
        try file.seek(toOffset: layout.dataOffset - 4)
        try file.write(contentsOf: bytes(UInt32(layout.byteCount)))
        try file.close()
        if FileManager.default.fileExists(atPath: recovered.path) {
            _ = try FileManager.default.replaceItemAt(recovered, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: recovered)
        }
        return recovered
    }

    /// Concatenate normalized chunks in bounded blocks. Resampling averages the
    /// input over each output sample period, including across block boundaries.
    static func append(_ url: URL, to output: Writer) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let layout = try inspect(input)
        guard layout.byteCount > 0 else { throw Failure.empty }
        try input.seek(toOffset: layout.dataOffset)
        var remaining = layout.byteCount
        var outputTicks = layout.rate
        var sum: Double = 0
        let blockBytes = 4096 * layout.frameBytes
        while remaining > 0 {
            let block = try read(input, count: Int(min(remaining, UInt64(blockBytes))))
            remaining -= UInt64(block.count)
            if layout.rate == Writer.rate, layout.channels == 1, layout.bits == 16, !layout.floating {
                try output.write(block)
                continue
            }
            var samples: [Int16] = []
            samples.reserveCapacity(block.count / layout.frameBytes * Writer.rate / layout.rate + 2)
            block.withUnsafeBytes { buffer in
                for offset in stride(from: 0, to: buffer.count, by: layout.frameBytes) {
                    var mono: Double = 0
                    for channel in 0..<layout.channels {
                        mono += sample(buffer, offset + channel * layout.sampleBytes, layout)
                    }
                    mono /= Double(layout.channels)
                    var inputTicks = Writer.rate
                    while inputTicks > 0 {
                        let ticks = min(inputTicks, outputTicks)
                        sum += mono * Double(ticks)
                        inputTicks -= ticks
                        outputTicks -= ticks
                        if outputTicks == 0 {
                            samples.append(quantize(sum / Double(layout.rate)))
                            sum = 0
                            outputTicks = layout.rate
                        }
                    }
                }
            }
            try output.write(samples)
        }
        let tail = layout.rate - outputTicks
        if tail > 0, tail * 2 >= layout.rate { try output.write([quantize(sum / Double(tail))]) }
    }

    final class Writer {
        static let rate = 16000
        private let file: FileHandle
        private(set) var byteCount: UInt64 = 0

        init(_ url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            file = try FileHandle(forWritingTo: url)
            try file.write(contentsOf: Data(repeating: 0, count: 44))
        }

        deinit { try? file.close() }

        func write(_ data: Data) throws {
            guard byteCount + UInt64(data.count) <= UInt64(UInt32.max - 36) else { throw Failure.tooLarge }
            try file.write(contentsOf: data)
            byteCount += UInt64(data.count)
        }

        func write(_ samples: [Int16]) throws {
            if !samples.isEmpty { try write(samples.withUnsafeBufferPointer { Data(buffer: $0) }) }
        }

        func finish() throws {
            guard byteCount > 0 else { throw Failure.empty }
            let length = UInt32(byteCount)
            var header = Data("RIFF".utf8)
            header.append(bytes(length + 36))
            header.append(Data("WAVEfmt ".utf8))
            header.append(bytes(UInt32(16)))
            header.append(bytes(UInt16(1))) // PCM
            header.append(bytes(UInt16(1))) // mono
            header.append(bytes(UInt32(Self.rate)))
            header.append(bytes(UInt32(Self.rate * 2)))
            header.append(bytes(UInt16(2)))
            header.append(bytes(UInt16(16)))
            header.append(Data("data".utf8))
            header.append(bytes(length))
            try file.seek(toOffset: 0)
            try file.write(contentsOf: header)
            try file.close()
        }
    }

    static func quantize(_ sample: Double) -> Int16 {
        Int16(max(-32768, min(32767, sample.isFinite ? sample.rounded() : 0))).littleEndian
    }

    private static func sample(_ buffer: UnsafeRawBufferPointer, _ offset: Int, _ layout: Layout) -> Double {
        switch layout.bits {
        case 8: return (Double(buffer[offset]) - 128) * 256
        case 16: return Double(Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
        case 24:
            let value = UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8 | UInt32(buffer[offset + 2]) << 16
            return Double(Int32(bitPattern: value << 8) >> 8) / 256
        default:
            let value = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            if !layout.floating { return Double(Int32(bitPattern: value)) / 65536 }
            let float = Double(Float(bitPattern: value))
            return float.isFinite ? max(-1, min(1, float)) * 32768 : 0
        }
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let block = try file.read(upToCount: count - result.count), !block.isEmpty else { throw Failure.damaged }
            result.append(block)
        }
        return result
    }

    private static func tag(_ data: Data, _ offset: Int) -> String {
        String(decoding: data[offset..<offset + 4], as: UTF8.self)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
