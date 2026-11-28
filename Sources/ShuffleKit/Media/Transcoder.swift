// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

@preconcurrency import AVFoundation
import Foundation

/// The formats a file can be converted to before it goes onto the iPod.
public enum AudioTarget: Sendable, Equatable, Codable {
    /// 16-bit PCM in a WAV file.
    case wav16
    case appleLossless
    case aac(bitrate: Int)

    public var fileExtension: String {
        if case .wav16 = self { return "wav" }
        return "m4a"
    }
}

public enum TranscodeError: ShuffleError {
    case cannotDecode(String)
    case cannotEncode(String)
    case exportFailed(String)

    public var description: String {
        switch self {
        case let .cannotDecode(reason): return "the audio could not be decoded: \(reason)"
        case let .cannotEncode(reason): return "the audio could not be converted: \(reason)"
        case let .exportFailed(reason): return "the file could not be repackaged: \(reason)"
        }
    }
}

struct ConversionResult: Sendable, Equatable {
    var frames: Int64
    var sampleRate: Int
    var channels: Int
}

/// Conversions for files the iPod cannot play as they are. Everything uses the decoders and
/// encoders that ship with macOS, so there is nothing to install.
enum Transcoder {
    private static let standardRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

    /// The iPod tops out at 48 kHz; anything above is brought down to 44.1 or 48 kHz.
    static func outputRate(for source: Double) -> Double {
        if standardRates.contains(source) { return source }
        if source > 48000 { return source.truncatingRemainder(dividingBy: 48000) == 0 ? 48000 : 44100 }
        return standardRates.first { $0 >= source } ?? 44100
    }

    /// Decodes `source` and writes it as `target` at `destination`. Stereo at most, 16-bit for lossless targets.
    static func convert(source: URL, to target: AudioTarget, destination: URL) async throws -> ConversionResult {
        let result = try decodeAndEncode(source: source, target: target, destination: destination)
        if target != .wav16, !MP4File.isFastStart(destination) {
            let optimized = destination.deletingLastPathComponent()
                .appendingPathComponent("faststart-" + destination.lastPathComponent)
            try await remux(source: destination, destination: optimized)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: optimized, to: destination)
        }
        return result
    }

    /// Repackages MPEG-4 audio without re-encoding: audio track only, index at the front.
    static func remux(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError.exportFailed("no audio track")
        }

        var exportAsset: AVAsset = asset
        if tracks.count > 1 {
            // Leave video, chapters and extra audio behind.
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TranscodeError.exportFailed("could not prepare the audio track")
            }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audio, at: .zero)
            exportAsset = composition
        }
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetPassthrough) else {
            throw TranscodeError.exportFailed("no export session")
        }
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw TranscodeError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: Decode and encode

    private static func decodeAndEncode(source: URL, target: AudioTarget, destination: URL) throws -> ConversionResult {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw TranscodeError.cannotDecode(error.localizedDescription)
        }
        let channels = AVAudioChannelCount(min(max(input.processingFormat.channelCount, 1), 2))
        let rate = outputRate(for: input.processingFormat.sampleRate)
        try? FileManager.default.removeItem(at: destination)

        if case .wav16 = target {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: channels, interleaved: true) else {
                throw TranscodeError.cannotEncode("unsupported PCM layout")
            }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            // The header is written twice: once as a placeholder, again when the length is known.
            try handle.write(contentsOf: WAVFile.header(sampleRate: Int(rate), channels: Int(channels), dataLength: 0))
            var byteCount: Int64 = 0
            try pump(from: input, to: format, dither: true) { buffer in
                let count = Int(buffer.frameLength) * Int(channels) * 2
                guard count > 0, let samples = buffer.int16ChannelData?[0] else { return }
                try handle.write(contentsOf: Data(bytes: samples, count: count))
                byteCount += Int64(count)
            }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAVFile.header(sampleRate: Int(rate), channels: Int(channels), dataLength: byteCount))
            return ConversionResult(frames: byteCount / Int64(channels * 2), sampleRate: Int(rate), channels: Int(channels))
        }

        let output = try makeCompressedFile(destination, target: target, rate: rate, channels: Int(channels))
        var frames: Int64 = 0
        do {
            try pump(from: input, to: output.processingFormat, dither: false) { buffer in
                try output.write(from: buffer)
                frames += Int64(buffer.frameLength)
            }
        } catch let error as TranscodeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscodeError.cannotEncode(error.localizedDescription)
        }
        return ConversionResult(frames: frames, sampleRate: Int(rate), channels: Int(channels))
    }

    private static func makeCompressedFile(_ url: URL, target: AudioTarget, rate: Double, channels: Int) throws -> AVAudioFile {
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        switch target {
        case .appleLossless:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 16
        case let .aac(bitrate):
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            // The encoder only accepts high bit rates at CD-like sample rates; elsewhere its default is used.
            if rate >= 44100 { settings[AVEncoderBitRateKey] = channels == 1 ? min(bitrate, 128_000) : bitrate }
        case .wav16:
            preconditionFailure("handled by the caller")
        }
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            guard settings.removeValue(forKey: AVEncoderBitRateKey) != nil else {
                throw TranscodeError.cannotEncode(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: url)
            do {
                return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw TranscodeError.cannotEncode(error.localizedDescription)
            }
        }
    }

    private final class PumpState {
        var finished = false
        var readError: Error?
    }

    /// Reads the whole input, converting sample rate, channel count and sample format as needed,
    /// and hands each converted block to `sink`.
    private static func pump(
        from input: AVAudioFile, to outFormat: AVAudioFormat, dither: Bool, sink: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        let inFormat = input.processingFormat
        let capacity: AVAudioFrameCount = 32768
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: capacity) else {
            throw TranscodeError.cannotDecode("could not allocate a buffer")
        }

        // Reading at the end of the file is an error rather than an empty read, so the position is checked first.
        if inFormat == outFormat {
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: inBuffer)
                if inBuffer.frameLength == 0 { return }
                try sink(inBuffer)
            }
            return
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscodeError.cannotEncode("no converter for this format")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.dither = dither
        let outCapacity = AVAudioFrameCount(Double(capacity) * outFormat.sampleRate / inFormat.sampleRate) + 1024
        let state = PumpState()

        while true {
            try Task.checkCancellation()
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw TranscodeError.cannotEncode("could not allocate a buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if state.finished || input.framePosition >= input.length {
                    state.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuffer)
                } catch {
                    state.readError = error
                    state.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    state.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let readError = state.readError { throw TranscodeError.cannotDecode(readError.localizedDescription) }
            if status == .error {
                throw TranscodeError.cannotEncode(conversionError?.localizedDescription ?? "conversion failed")
            }
            if outBuffer.frameLength > 0 { try sink(outBuffer) }
            if status == .endOfStream || (state.finished && outBuffer.frameLength == 0) { return }
        }
    }
}
