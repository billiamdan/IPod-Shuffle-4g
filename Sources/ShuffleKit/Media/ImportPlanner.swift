// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What to do with uncompressed and lossless music, which is large for a 2 GB player.
public enum LosslessPolicy: String, Codable, Sendable, CaseIterable {
    /// Keep the format; convert only what the iPod cannot play.
    case keep
    /// Store WAV, AIFF and FLAC as Apple Lossless: same sound, roughly half the size.
    case appleLossless
    /// Convert lossless and uncompressed audio to AAC: much smaller, no longer lossless.
    case aac
}

public struct ImportSettings: Codable, Sendable, Equatable {
    public var lossless: LosslessPolicy
    public var aacBitrate: Int

    public init(lossless: LosslessPolicy = .keep, aacBitrate: Int = 256_000) {
        self.lossless = lossless
        self.aacBitrate = aacBitrate
    }
}

public struct ImportPlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Byte-for-byte copy.
        case copy
        /// Same samples, WAV chunks rewritten in the layout the iPod accepts.
        case rewrapWAV
        /// Same audio, MPEG-4 container rewritten with the index first.
        case remux
        case convert(AudioTarget)
    }

    public var action: Action
    /// The code the database must carry so the iPod picks the right decoder.
    public var fileType: UInt32
    public var fileExtension: String
    /// Label of the result: "MP3", "AAC", "Apple Lossless", "WAV".
    public var kind: String
    /// Why the file is being converted, for the import report. `nil` when it goes over as it is.
    public var note: String?
}

public enum ImportError: ShuffleError, Equatable {
    case protectedContent
    case unsupported(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case nameCollision

    public var description: String {
        switch self {
        case .protectedContent:
            return "copy-protected purchase; the iPod can only be authorised for it by Apple's own sync"
        case let .unsupported(what):
            return "\(what) is not a format the iPod or macOS can handle"
        case let .notEnoughSpace(needed, available):
            let formatter = ByteCountFormatter()
            return "not enough room on the iPod: needs \(formatter.string(fromByteCount: needed)), \(formatter.string(fromByteCount: available)) free"
        case .nameCollision:
            return "could not find a free file name on the iPod"
        }
    }
}

/// Decides how each kind of file gets onto the iPod.
///
/// Confirmed by listening on an iPod shuffle 4G: MP3 plays with code 1; AAC and Apple Lossless with
/// code 2; 16-bit WAV with code 4. The firmware trusts the code, so it has to match the content.
public enum ImportPlanner {
    /// - Parameters:
    ///   - isFastStart: for MPEG-4 files, whether the index already sits before the audio.
    ///   - wavFormat: for WAV files, the parsed `fmt ` chunk.
    public static func plan(
        for info: MediaInfo, isFastStart: Bool = true, wavFormat: WAVFormat? = nil, settings: ImportSettings = ImportSettings()
    ) throws -> ImportPlan {
        if info.isProtected { throw ImportError.protectedContent }

        let aac = AudioTarget.aac(bitrate: settings.aacBitrate)
        let playableLayout = info.channels <= 2 && info.sampleRate <= 48000

        switch info.codec {
        case .mp3:
            guard info.container == .mp3 else {
                return converted(to: aac, note: "MP3 audio inside another container; converted to AAC")
            }
            return ImportPlan(action: .copy, fileType: FileTypeCode.mp3, fileExtension: "mp3", kind: "MP3", note: nil)

        case .aac:
            guard playableLayout else {
                return converted(to: aac, note: "more than two channels or above 48 kHz; converted to stereo AAC")
            }
            let needsRemux = info.container != .mpeg4 || !isFastStart || info.hasVideo
            return ImportPlan(
                action: needsRemux ? .remux : .copy, fileType: FileTypeCode.mpeg4, fileExtension: "m4a", kind: "AAC",
                note: needsRemux ? "repackaged without re-encoding so the iPod can read it" : nil
            )

        case .appleLossless:
            if settings.lossless == .aac { return converted(to: aac, note: "converted to AAC to save space") }
            guard playableLayout, (info.bitDepth ?? 16) <= 16 else {
                return converted(to: .appleLossless, note: "high-resolution audio; converted to 16-bit Apple Lossless")
            }
            let needsRemux = info.container != .mpeg4 || !isFastStart || info.hasVideo
            return ImportPlan(
                action: needsRemux ? .remux : .copy, fileType: FileTypeCode.mpeg4, fileExtension: "m4a", kind: "Apple Lossless",
                note: needsRemux ? "repackaged without re-encoding so the iPod can read it" : nil
            )

        case .pcm:
            switch settings.lossless {
            case .aac: return converted(to: aac, note: "converted to AAC to save space")
            case .appleLossless: return converted(to: .appleLossless, note: "stored as Apple Lossless to save space")
            case .keep: break
            }
            if info.container == .wav, let wavFormat, wavFormat.isPlainPCM16 {
                return ImportPlan(action: .rewrapWAV, fileType: FileTypeCode.wav, fileExtension: "wav", kind: "WAV", note: nil)
            }
            let reason = info.container == .wav ? "not 16-bit stereo PCM; converted to 16-bit WAV" : "\(info.kindLabel) stored as 16-bit WAV"
            return converted(to: .wav16, note: reason)

        case .flac:
            if settings.lossless == .aac { return converted(to: aac, note: "converted to AAC to save space") }
            return converted(to: .appleLossless, note: "FLAC stored as Apple Lossless")

        case .other:
            return converted(to: aac, note: "format the iPod does not play; converted to AAC")
        }
    }

    private static func converted(to target: AudioTarget, note: String) -> ImportPlan {
        switch target {
        case .wav16:
            return ImportPlan(action: .convert(target), fileType: FileTypeCode.wav, fileExtension: "wav", kind: "WAV", note: note)
        case .appleLossless:
            return ImportPlan(action: .convert(target), fileType: FileTypeCode.mpeg4, fileExtension: "m4a", kind: "Apple Lossless", note: note)
        case .aac:
            return ImportPlan(action: .convert(target), fileType: FileTypeCode.mpeg4, fileExtension: "m4a", kind: "AAC", note: note)
        }
    }
}
