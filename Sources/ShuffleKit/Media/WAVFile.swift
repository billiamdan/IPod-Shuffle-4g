import Foundation

/// The `fmt ` chunk of a WAV file.
public struct WAVFormat: Sendable, Equatable {
    /// 1 integer PCM, 3 floating point, 0xFFFE "extensible" (the real tag is then in `subFormatTag`).
    public var formatTag: UInt16
    public var channels: Int
    public var sampleRate: Int
    public var bitsPerSample: Int
    public var blockAlign: Int
    public var subFormatTag: UInt16?

    /// 16-bit integer PCM, mono or stereo, at a rate the iPod plays: can be copied without re-encoding.
    public var isPlainPCM16: Bool {
        let tag = formatTag == 0xFFFE ? (subFormatTag ?? 0) : formatTag
        return tag == 1 && bitsPerSample == 16 && (1...2).contains(channels) && (8000...48000).contains(sampleRate)
            && blockAlign == channels * 2
    }
}

public struct WAVLayout: Sendable, Equatable {
    public var format: WAVFormat
    public var dataOffset: Int64
    public var dataLength: Int64

    public var frameCount: Int64 { format.blockAlign > 0 ? dataLength / Int64(format.blockAlign) : 0 }
}

public enum WAVError: ShuffleError, Equatable {
    case notWAV
    case missingChunk(String)

    public var description: String {
        switch self {
        case .notWAV: return "not a WAV file"
        case let .missingChunk(name): return "the WAV file has no '\(name)' chunk"
        }
    }
}

/// Reads any WAV chunk layout and writes the one the iPod is known to accept.
///
/// Every WAV on the iPod that Apple's software wrote looks the same: the `fmt ` chunk first, then a
/// `FLLR` padding chunk, then `data` with the samples starting at byte 4096. Files from other tools put
/// extra chunks in front (`JUNK`, `LIST`, `bext`), which the firmware has never been seen to handle, so
/// everything is rewritten into Apple's layout. The samples themselves are copied untouched.
public enum WAVFile {
    static let headerLength = 4096
    private static let fillerLength = headerLength - 12 - 24 - 8 - 8

    public static func inspect(_ url: URL) throws -> WAVLayout {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard let riff = try handle.read(upToCount: 12), riff.count == 12,
              String(decoding: riff.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: riff.suffix(4), as: UTF8.self) == "WAVE" else { throw WAVError.notWAV }

        var format: WAVFormat?
        var data: (offset: Int64, length: Int64)?
        var position: Int64 = 12
        while position + 8 <= fileSize, format == nil || data == nil {
            try handle.seek(toOffset: UInt64(position))
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let reader = ByteReader(header)
            let id = try reader.tag(0)
            var size = Int64(try reader.u32(4))
            let body = position + 8
            if id == "fmt " {
                guard let raw = try handle.read(upToCount: Int(min(size, 40))), raw.count >= 16 else { throw WAVError.notWAV }
                let fields = ByteReader(raw)
                format = WAVFormat(
                    formatTag: try fields.u16(0), channels: Int(try fields.u16(2)), sampleRate: Int(try fields.u32(4)),
                    bitsPerSample: Int(try fields.u16(14)), blockAlign: Int(try fields.u16(12)),
                    subFormatTag: raw.count >= 26 ? try fields.u16(24) : nil
                )
            } else if id == "data" {
                // Streamed recordings leave the length as 0 or 0xFFFFFFFF; the samples then run to the end of the file.
                if size == 0 || size == 0xFFFF_FFFF || body + size > fileSize { size = fileSize - body }
                data = (body, size)
            }
            position = body + size + (size & 1)
        }
        guard let format else { throw WAVError.missingChunk("fmt ") }
        guard let data else { throw WAVError.missingChunk("data") }
        return WAVLayout(format: format, dataOffset: data.offset, dataLength: data.length)
    }

    /// The 4096-byte header in Apple's layout for 16-bit PCM.
    static func header(sampleRate: Int, channels: Int, dataLength: Int64) -> Data {
        let padded = dataLength + (dataLength & 1)
        var out = ByteWriter()
        out.tag("RIFF")
        out.u32(UInt32(truncatingIfNeeded: Int64(headerLength - 8) + padded))
        out.tag("WAVE")
        out.tag("fmt ")
        out.u32(16)
        out.u16(1)
        out.u16(UInt16(channels))
        out.u32(UInt32(sampleRate))
        out.u32(UInt32(sampleRate * channels * 2))
        out.u16(UInt16(channels * 2))
        out.u16(16)
        out.tag("FLLR")
        out.u32(UInt32(fillerLength))
        out.zeros(fillerLength)
        out.tag("data")
        out.u32(UInt32(truncatingIfNeeded: dataLength))
        precondition(out.count == headerLength)
        return Data(out.bytes)
    }

    /// A complete WAV file for a short clip held in memory (16-bit little-endian samples).
    public static func file(samples: Data, sampleRate: Int, channels: Int) -> Data {
        var data = header(sampleRate: sampleRate, channels: channels, dataLength: Int64(samples.count))
        data.append(samples)
        if samples.count % 2 == 1 { data.append(0) }
        return data
    }

    /// Copies the samples of a plain 16-bit WAV into a new file with Apple's chunk layout.
    static func rewrap(source: URL, layout: WAVLayout, to destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        precondition(layout.format.isPlainPCM16)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(layout.dataOffset))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
            try output.write(contentsOf: header(
                sampleRate: layout.format.sampleRate, channels: layout.format.channels, dataLength: layout.dataLength
            ))
            var remaining = layout.dataLength
            var written = Int64(headerLength)
            while remaining > 0 {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
                written += Int64(chunk.count)
                progress?(written)
            }
            if layout.dataLength % 2 == 1 { try output.write(contentsOf: Data([0])) }
            try output.synchronize()
            try output.close()
            guard remaining == 0 else {
                throw FileOpsError.sizeMismatch(path: destination.path, expected: layout.dataLength, actual: layout.dataLength - remaining)
            }
        } catch {
            try? output.close()
            FileOps.remove(destination)
            throw error
        }
        FileOps.removeSidecar(for: destination)
    }
}
