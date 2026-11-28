// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import Foundation
@testable import ShuffleKit

/// Small audio files generated on the fly, so the repository carries no music.
enum AudioFixtures {
    /// 16-bit little-endian samples of a 440 Hz tone.
    static func tone(seconds: Double, sampleRate: Int = 44100, channels: Int = 2) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        var data = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(8000 * sin(2 * Double.pi * 440 * Double(frame) / Double(sampleRate)))
            for _ in 0..<channels {
                data.append(UInt8(truncatingIfNeeded: value))
                data.append(UInt8(truncatingIfNeeded: value >> 8))
            }
        }
        return data
    }

    /// A WAV in the simplest possible layout: `fmt ` immediately followed by `data`.
    @discardableResult
    static func wav(at url: URL, seconds: Double = 1, sampleRate: Int = 44100, channels: Int = 2, bits: Int = 16) throws -> Data {
        var samples = tone(seconds: seconds, sampleRate: sampleRate, channels: channels)
        if bits == 24 {
            // Widen each 16-bit sample to 24 bits by adding a zero low byte.
            var wide = Data(capacity: samples.count / 2 * 3)
            for index in stride(from: 0, to: samples.count, by: 2) {
                wide.append(0)
                wide.append(samples[index])
                wide.append(samples[index + 1])
            }
            samples = wide
        }
        let bytesPerFrame = channels * bits / 8
        var file = Data("RIFF".utf8)
        file.append(le32(36 + samples.count))
        file.append(Data("WAVEfmt ".utf8))
        file.append(le32(16))
        file.append(le16(1))
        file.append(le16(channels))
        file.append(le32(sampleRate))
        file.append(le32(sampleRate * bytesPerFrame))
        file.append(le16(bytesPerFrame))
        file.append(le16(bits))
        file.append(Data("data".utf8))
        file.append(le32(samples.count))
        file.append(samples)
        try file.write(to: url)
        return samples
    }

    /// A WAV the way some tools write it: a `JUNK` chunk first, an "extensible" `fmt ` chunk, a `LIST` chunk before the samples.
    @discardableResult
    static func awkwardWAV(at url: URL, seconds: Double = 0.5) throws -> Data {
        let samples = tone(seconds: seconds)
        var fmt = Data()
        fmt.append(le16(0xFFFE))
        fmt.append(le16(2))
        fmt.append(le32(44100))
        fmt.append(le32(44100 * 4))
        fmt.append(le16(4))
        fmt.append(le16(16))
        fmt.append(le16(22))            // size of the extension
        fmt.append(le16(16))            // valid bits
        fmt.append(le32(3))             // speaker mask
        fmt.append(le16(1))             // sub-format: integer PCM ...
        fmt.append(Data(repeating: 0, count: 14))  // ... rest of the GUID (not examined)

        var body = Data("WAVE".utf8)
        body.append(Data("JUNK".utf8)); body.append(le32(28)); body.append(Data(repeating: 0, count: 28))
        body.append(Data("fmt ".utf8)); body.append(le32(fmt.count)); body.append(fmt)
        body.append(Data("LIST".utf8)); body.append(le32(10)); body.append(Data("INFOabcdef".utf8))
        body.append(Data("data".utf8)); body.append(le32(samples.count)); body.append(samples)
        var file = Data("RIFF".utf8)
        file.append(le32(body.count))
        file.append(body)
        try file.write(to: url)
        return samples
    }

    /// Silent MPEG-1 Layer III frames: a real MP3 as far as decoders are concerned (macOS ships no MP3 encoder).
    static func mp3(at url: URL, frames: Int = 120) throws {
        let frame = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        var file = Data()
        for _ in 0..<frames { file.append(frame) }
        try file.write(to: url)
    }

    /// Writes a tone through Core Audio in whatever format the settings ask for (AIFF, FLAC, ...).
    static func encoded(at url: URL, settings: [String: Any], seconds: Double = 1, sampleRate: Double = 44100) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    private static func le16(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    private static func le32(_ value: Int) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
}
