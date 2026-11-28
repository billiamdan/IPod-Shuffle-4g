// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

@preconcurrency import AVFoundation
import Foundation

/// What an audio file is, as far as importing it is concerned.
public struct MediaInfo: Sendable, Equatable {
    public enum Container: String, Sendable {
        case mp3, mpeg4, wav, aiff, flac, caf, adts, other
    }

    public enum Codec: String, Sendable {
        case mp3, aac, appleLossless, pcm, flac, other
    }

    public var container: Container
    public var codec: Codec
    public var durationMs: Int
    public var sampleRate: Int
    public var channels: Int
    /// Bits per sample of PCM, or of the source for Apple Lossless and FLAC.
    public var bitDepth: Int?
    public var bitrateKbps: Int?
    public var sizeBytes: Int64
    /// Bought music with copy protection. The iPod cannot be authorised to play it from here.
    public var isProtected: Bool
    public var hasVideo: Bool
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?

    public init(
        container: Container, codec: Codec, durationMs: Int = 0, sampleRate: Int = 44100, channels: Int = 2,
        bitDepth: Int? = nil, bitrateKbps: Int? = nil, sizeBytes: Int64 = 0, isProtected: Bool = false, hasVideo: Bool = false,
        title: String? = nil, artist: String? = nil, album: String? = nil, genre: String? = nil,
        trackNumber: Int? = nil, discNumber: Int? = nil
    ) {
        self.container = container
        self.codec = codec
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.bitrateKbps = bitrateKbps
        self.sizeBytes = sizeBytes
        self.isProtected = isProtected
        self.hasVideo = hasVideo
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }

    /// A short label for lists: "MP3", "AAC", "Apple Lossless", "WAV", ...
    public var kindLabel: String {
        switch codec {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .appleLossless: return "Apple Lossless"
        case .flac: return "FLAC"
        case .pcm:
            switch container {
            case .wav: return "WAV"
            case .aiff: return "AIFF"
            default: return "PCM"
            }
        case .other: return "Audio"
        }
    }

    public var tags: ProbedTags {
        ProbedTags(
            title: title, artist: artist, album: album, genre: genre, kind: kindLabel,
            durationMs: durationMs, bitrateKbps: bitrateKbps, sampleRate: sampleRate
        )
    }
}

public enum MediaError: ShuffleError, Equatable {
    case notAudio
    case unreadable(String)

    public var description: String {
        switch self {
        case .notAudio: return "the file has no audio in a format macOS can read"
        case let .unreadable(reason): return "the file could not be read: \(reason)"
        }
    }
}

public enum MediaProbe {
    /// File extensions worth looking at when a folder is dropped.
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "mp4", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "alac",
    ]

    public static func probe(_ url: URL) async throws -> MediaInfo {
        guard let size = FileOps.fileSize(url) else { throw MediaError.unreadable("file not found") }
        let magic = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 12)
        } ?? Data()

        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return try fallbackProbe(url, size: size, magic: magic, reason: error.localizedDescription)
        }
        guard let track = audioTracks.first else {
            return try fallbackProbe(url, size: size, magic: magic, reason: nil)
        }
        guard let description = try await track.load(.formatDescriptions).first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw MediaError.notAudio
        }

        let (codec, depth) = classify(format)
        var info = MediaInfo(container: container(magic: magic, codec: codec), codec: codec, sizeBytes: size)
        info.bitDepth = depth
        info.sampleRate = Int(format.mSampleRate.rounded())
        info.channels = Int(format.mChannelsPerFrame)

        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        info.durationMs = seconds.isFinite && seconds > 0 ? Int((seconds * 1000).rounded()) : 0
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0
        if rate > 0 {
            info.bitrateKbps = Int((rate / 1000).rounded())
        } else if info.durationMs > 0 {
            info.bitrateKbps = Int(Double(size) * 8 / Double(info.durationMs))
        }
        info.isProtected = (try? await asset.load(.hasProtectedContent)) ?? false
        info.hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty

        await readTags(asset, into: &info)
        return info
    }

    // MARK: Classification

    private static func classify(_ format: AudioStreamBasicDescription) -> (MediaInfo.Codec, Int?) {
        switch format.mFormatID {
        case kAudioFormatMPEGLayer3:
            return (.mp3, nil)
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            return (.aac, nil)
        case kAudioFormatAppleLossless:
            return (.appleLossless, sourceBitDepth(flags: format.mFormatFlags))
        case kAudioFormatFLAC:
            return (.flac, sourceBitDepth(flags: format.mFormatFlags))
        case kAudioFormatLinearPCM:
            return (.pcm, Int(format.mBitsPerChannel))
        default:
            return (.other, nil)
        }
    }

    /// Apple Lossless and FLAC descriptions carry the source bit depth as a small code in the flags.
    private static func sourceBitDepth(flags: AudioFormatFlags) -> Int? {
        switch flags {
        case 1: return 16
        case 2: return 20
        case 3: return 24
        case 4: return 32
        default: return nil
        }
    }

    private static func container(magic: Data, codec: MediaInfo.Codec) -> MediaInfo.Container {
        let bytes = [UInt8](magic)
        func text(_ range: Range<Int>) -> String {
            bytes.count >= range.upperBound ? String(decoding: bytes[range], as: UTF8.self) : ""
        }
        if text(0..<4) == "RIFF", text(8..<12) == "WAVE" { return .wav }
        if text(0..<4) == "FORM", ["AIFF", "AIFC"].contains(text(8..<12)) { return .aiff }
        if text(0..<4) == "fLaC" { return .flac }
        if text(0..<4) == "caff" { return .caf }
        if text(4..<8) == "ftyp" { return .mpeg4 }
        switch codec {
        case .mp3: return .mp3
        case .aac: return .adts
        default: return .other
        }
    }

    /// For files `AVURLAsset` will not open as a movie but Core Audio can still decode.
    private static func fallbackProbe(_ url: URL, size: Int64, magic: Data, reason: String?) throws -> MediaInfo {
        guard let file = try? AVAudioFile(forReading: url) else {
            if let reason { throw MediaError.unreadable(reason) }
            throw MediaError.notAudio
        }
        let format = file.fileFormat.streamDescription.pointee
        let (codec, depth) = classify(format)
        var info = MediaInfo(container: container(magic: magic, codec: codec), codec: codec, sizeBytes: size)
        info.bitDepth = depth
        info.sampleRate = Int(format.mSampleRate.rounded())
        info.channels = Int(format.mChannelsPerFrame)
        if format.mSampleRate > 0 {
            info.durationMs = Int((Double(file.length) / format.mSampleRate * 1000).rounded())
        }
        if info.durationMs > 0 { info.bitrateKbps = Int(Double(size) * 8 / Double(info.durationMs)) }
        return info
    }

    // MARK: Tags

    private static func readTags(_ asset: AVURLAsset, into info: inout MediaInfo) async {
        guard let items = try? await asset.load(.metadata) else { return }
        for item in items {
            if let key = item.commonKey {
                guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                switch key {
                case .commonKeyTitle: info.title = info.title ?? value
                case .commonKeyArtist: info.artist = info.artist ?? value
                case .commonKeyAlbumName: info.album = info.album ?? value
                default: break
                }
                continue
            }
            guard let identifier = item.identifier else { continue }
            switch identifier {
            case .id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre:
                if let value = try? await item.load(.stringValue), !value.isEmpty { info.genre = info.genre ?? value }
            case .id3MetadataTrackNumber:
                if let value = try? await item.load(.stringValue) { info.trackNumber = leadingNumber(value) }
            case .id3MetadataPartOfASet:
                if let value = try? await item.load(.stringValue) { info.discNumber = leadingNumber(value) }
            case .iTunesMetadataTrackNumber:
                if let value = try? await item.load(.dataValue) { info.trackNumber = packedNumber(value) }
            case .iTunesMetadataDiscNumber:
                if let value = try? await item.load(.dataValue) { info.discNumber = packedNumber(value) }
            default:
                break
            }
        }
    }

    /// "3/12" → 3.
    private static func leadingNumber(_ text: String) -> Int? {
        Int(text.prefix { $0.isNumber })
    }

    /// MPEG-4 stores "track 3 of 12" as bytes 00 00 00 03 00 0C ...
    private static func packedNumber(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return value > 0 ? value : nil
    }
}
