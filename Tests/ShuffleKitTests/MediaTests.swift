// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import Foundation
import Testing
@testable import ShuffleKit

@Suite("WAV files")
struct WAVTests {
    @Test("The header matches the layout of Apple's own files on the iPod")
    func headerLayout() throws {
        let file = WAVFile.file(samples: AudioFixtures.tone(seconds: 0.1, sampleRate: 22050, channels: 1), sampleRate: 22050, channels: 1)
        let bytes = [UInt8](file)

        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: bytes[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(bytes[16..<20] == [16, 0, 0, 0])
        #expect(String(decoding: bytes[36..<40], as: UTF8.self) == "FLLR")
        #expect(bytes[40..<44] == [0xCC, 0x0F, 0, 0])            // 4044 bytes of padding
        #expect(String(decoding: bytes[4088..<4092], as: UTF8.self) == "data")
        #expect(file.count == 4096 + 2205 * 2)

        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("clip.wav")
        try file.write(to: url)
        let layout = try WAVFile.inspect(url)
        #expect(layout.dataOffset == 4096)
        #expect(layout.format.sampleRate == 22050)
        #expect(layout.format.channels == 1)
        #expect(layout.frameCount == 2205)
    }

    @Test("A WAV with extra chunks and an extensible header is rewrapped with identical samples")
    func rewrapsAwkwardLayout() throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("awkward.wav")
        let samples = try AudioFixtures.awkwardWAV(at: source)

        let layout = try WAVFile.inspect(source)
        #expect(layout.format.formatTag == 0xFFFE)
        #expect(layout.format.isPlainPCM16)
        #expect(layout.dataLength == Int64(samples.count))

        let output = directory.url.appendingPathComponent("clean.wav")
        try WAVFile.rewrap(source: source, layout: layout, to: output)
        let result = try Data(contentsOf: output)
        #expect(result == WAVFile.file(samples: samples, sampleRate: 44100, channels: 2))
        #expect(try WAVFile.inspect(output).format.formatTag == 1)
    }

    @Test("Only 16-bit stereo-or-mono PCM up to 48 kHz counts as playable as it is")
    func plainness() throws {
        let directory = try TemporaryDirectory()
        func layout(bits: Int = 16, rate: Int = 44100, channels: Int = 2) throws -> WAVFormat {
            let url = directory.url.appendingPathComponent("\(bits)-\(rate)-\(channels).wav")
            try AudioFixtures.wav(at: url, seconds: 0.1, sampleRate: rate, channels: channels, bits: bits)
            return try WAVFile.inspect(url).format
        }
        #expect(try layout().isPlainPCM16)
        #expect(try layout(channels: 1).isPlainPCM16)
        #expect(try layout(rate: 48000).isPlainPCM16)
        #expect(try !layout(bits: 24).isPlainPCM16)
        #expect(try !layout(rate: 96000).isPlainPCM16)
    }

    @Test("Files that are not WAV are rejected")
    func rejectsOtherFiles() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("fake.wav")
        try Data(repeating: 0, count: 64).write(to: url)
        #expect(throws: WAVError.notWAV) { try WAVFile.inspect(url) }
    }
}

@Suite("Probing and converting audio")
struct MediaTests {
    @Test("A WAV is recognised with its sample format")
    func probesWAV() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("tone.wav")
        try AudioFixtures.wav(at: url, seconds: 1)

        let info = try await MediaProbe.probe(url)
        #expect(info.container == .wav)
        #expect(info.codec == .pcm)
        #expect(info.bitDepth == 16)
        #expect(info.channels == 2)
        #expect(info.sampleRate == 44100)
        #expect(abs(info.durationMs - 1000) <= 5)
        #expect(info.kindLabel == "WAV")
    }

    @Test("An MP3 is recognised and goes over untouched with type code 1")
    func probesMP3() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("silence.mp3")
        try AudioFixtures.mp3(at: url)

        let info = try await MediaProbe.probe(url)
        #expect(info.codec == .mp3)
        #expect(info.container == .mp3)
        #expect(info.durationMs > 2500)
        let plan = try ImportPlanner.plan(for: info)
        #expect(plan.action == .copy)
        #expect(plan.fileType == FileTypeCode.mp3)
    }

    @Test("WAV converts to Apple Lossless and AAC with the index at the front")
    func convertsToMPEG4() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("tone.wav")
        try AudioFixtures.wav(at: source, seconds: 1)

        let lossless = directory.url.appendingPathComponent("lossless.m4a")
        let result = try await Transcoder.convert(source: source, to: .appleLossless, destination: lossless)
        #expect(result.frames == 44100)
        let losslessInfo = try await MediaProbe.probe(lossless)
        #expect(losslessInfo.codec == .appleLossless)
        #expect(losslessInfo.container == .mpeg4)
        #expect(losslessInfo.bitDepth == 16)
        #expect(MP4File.isFastStart(lossless))
        #expect(try ImportPlanner.plan(for: losslessInfo, isFastStart: true).action == .copy)

        let aac = directory.url.appendingPathComponent("lossy.m4a")
        _ = try await Transcoder.convert(source: source, to: .aac(bitrate: 256_000), destination: aac)
        let aacInfo = try await MediaProbe.probe(aac)
        #expect(aacInfo.codec == .aac)
        #expect(MP4File.isFastStart(aac))
        #expect(abs(aacInfo.durationMs - 1000) < 80)
        #expect(try ImportPlanner.plan(for: aacInfo, isFastStart: true).action == .copy)
    }

    @Test("Repackaging keeps the audio and puts the index first")
    func remuxes() async throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("tone.wav")
        try AudioFixtures.wav(at: source, seconds: 1)
        let encoded = directory.url.appendingPathComponent("a.m4a")
        _ = try await Transcoder.convert(source: source, to: .aac(bitrate: 128_000), destination: encoded)

        let output = directory.url.appendingPathComponent("b.m4a")
        try await Transcoder.remux(source: encoded, destination: output)
        #expect(MP4File.isFastStart(output))
        let info = try await MediaProbe.probe(output)
        #expect(info.codec == .aac)
        #expect(abs(info.durationMs - 1000) < 80)
    }

    @Test("24-bit and 96 kHz WAV become 16-bit WAV at a rate the iPod plays")
    func convertsHighResolutionWAV() async throws {
        let directory = try TemporaryDirectory()

        let deep = directory.url.appendingPathComponent("24bit.wav")
        try AudioFixtures.wav(at: deep, seconds: 0.5, bits: 24)
        let deepInfo = try await MediaProbe.probe(deep)
        #expect(deepInfo.bitDepth == 24)
        let deepPlan = try ImportPlanner.plan(for: deepInfo, wavFormat: try WAVFile.inspect(deep).format)
        #expect(deepPlan.action == .convert(.wav16))
        #expect(deepPlan.fileType == FileTypeCode.wav)

        let output = directory.url.appendingPathComponent("16bit.wav")
        let result = try await Transcoder.convert(source: deep, to: .wav16, destination: output)
        #expect(result.frames == 22050)
        let layout = try WAVFile.inspect(output)
        #expect(layout.format.isPlainPCM16)
        #expect(layout.dataOffset == 4096)
        #expect(layout.frameCount == 22050)

        let fast = directory.url.appendingPathComponent("96k.wav")
        try AudioFixtures.wav(at: fast, seconds: 0.5, sampleRate: 96000)
        let slowed = directory.url.appendingPathComponent("48k.wav")
        let slowedResult = try await Transcoder.convert(source: fast, to: .wav16, destination: slowed)
        #expect(slowedResult.sampleRate == 48000)
        #expect(abs(slowedResult.frames - 24000) < 64)
    }

    @Test("AIFF is recognised and stored as WAV")
    func handlesAIFF() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("tone.aiff")
        try AudioFixtures.encoded(at: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false,
        ])
        let info = try await MediaProbe.probe(url)
        #expect(info.container == .aiff)
        #expect(info.codec == .pcm)

        let plan = try ImportPlanner.plan(for: info)
        #expect(plan.action == .convert(.wav16))
        let output = directory.url.appendingPathComponent("tone.wav")
        let result = try await Transcoder.convert(source: url, to: .wav16, destination: output)
        #expect(result.frames == 44100)
        #expect(try WAVFile.inspect(output).format.isPlainPCM16)
    }

    @Test("FLAC is recognised and planned as Apple Lossless")
    func handlesFLAC() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("tone.flac")
        do {
            try AudioFixtures.encoded(at: url, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2,
            ])
        } catch {
            return  // this macOS build has no FLAC encoder; decoding is covered by the planner test
        }
        let info = try await MediaProbe.probe(url)
        #expect(info.codec == .flac)
        #expect(try ImportPlanner.plan(for: info).action == .convert(.appleLossless))

        let output = directory.url.appendingPathComponent("tone.m4a")
        let result = try await Transcoder.convert(source: url, to: .appleLossless, destination: output)
        #expect(abs(result.frames - 44100) < 8)
    }

    @Test("Files that are not audio are reported, not crashed on")
    func rejectsNonAudio() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: url)
        await #expect(throws: MediaError.self) { try await MediaProbe.probe(url) }
    }

    @Test("Sample rates above 48 kHz are brought into range")
    func outputRates() {
        #expect(Transcoder.outputRate(for: 44100) == 44100)
        #expect(Transcoder.outputRate(for: 48000) == 48000)
        #expect(Transcoder.outputRate(for: 96000) == 48000)
        #expect(Transcoder.outputRate(for: 88200) == 44100)
        #expect(Transcoder.outputRate(for: 22050) == 22050)
        #expect(Transcoder.outputRate(for: 15000) == 16000)
    }
}

@Suite("Import rules")
struct ImportPlannerTests {
    private let plainWAV = WAVFormat(formatTag: 1, channels: 2, sampleRate: 44100, bitsPerSample: 16, blockAlign: 4, subFormatTag: nil)

    @Test("The four requested formats go over without re-encoding, each with the code the iPod needs")
    func nativeFormats() throws {
        let mp3 = try ImportPlanner.plan(for: MediaInfo(container: .mp3, codec: .mp3))
        #expect(mp3.action == .copy && mp3.fileType == 1 && mp3.fileExtension == "mp3")

        let aac = try ImportPlanner.plan(for: MediaInfo(container: .mpeg4, codec: .aac))
        #expect(aac.action == .copy && aac.fileType == 2 && aac.fileExtension == "m4a")

        let lossless = try ImportPlanner.plan(for: MediaInfo(container: .mpeg4, codec: .appleLossless, bitDepth: 16))
        #expect(lossless.action == .copy && lossless.fileType == 2 && lossless.kind == "Apple Lossless")

        let wav = try ImportPlanner.plan(for: MediaInfo(container: .wav, codec: .pcm, bitDepth: 16), wavFormat: plainWAV)
        #expect(wav.action == .rewrapWAV && wav.fileType == 4 && wav.fileExtension == "wav")
        #expect(mp3.note == nil && aac.note == nil && lossless.note == nil && wav.note == nil)
    }

    @Test("MPEG-4 files with the index at the end, or with video, are repackaged")
    func repackaging() throws {
        let late = try ImportPlanner.plan(for: MediaInfo(container: .mpeg4, codec: .aac), isFastStart: false)
        #expect(late.action == .remux)
        let video = try ImportPlanner.plan(for: MediaInfo(container: .mpeg4, codec: .aac, hasVideo: true))
        #expect(video.action == .remux)
        let raw = try ImportPlanner.plan(for: MediaInfo(container: .adts, codec: .aac))
        #expect(raw.action == .remux)
        #expect(late.note != nil)
    }

    @Test("Audio beyond what the iPod plays is converted, staying lossless where it was")
    func outOfRangeAudio() throws {
        let hiRes = try ImportPlanner.plan(for: MediaInfo(container: .mpeg4, codec: .appleLossless, sampleRate: 96000, bitDepth: 24))
        #expect(hiRes.action == .convert(.appleLossless))
        let surround = try ImportPlanner.plan(for: MediaInfo(container: .mpeg4, codec: .aac, channels: 6))
        #expect(surround.action == .convert(.aac(bitrate: 256_000)))
        let flac = try ImportPlanner.plan(for: MediaInfo(container: .flac, codec: .flac))
        #expect(flac.action == .convert(.appleLossless) && flac.fileType == 2)
        let aiff = try ImportPlanner.plan(for: MediaInfo(container: .aiff, codec: .pcm, bitDepth: 16))
        #expect(aiff.action == .convert(.wav16) && aiff.fileType == 4)
        let unknown = try ImportPlanner.plan(for: MediaInfo(container: .other, codec: .other))
        #expect(unknown.action == .convert(.aac(bitrate: 256_000)))
    }

    @Test("The space-saving settings apply to lossless and uncompressed audio only")
    func losslessPolicies() throws {
        let toLossless = ImportSettings(lossless: .appleLossless)
        let toAAC = ImportSettings(lossless: .aac, aacBitrate: 192_000)
        let wav = MediaInfo(container: .wav, codec: .pcm, bitDepth: 16)
        let lossless = MediaInfo(container: .mpeg4, codec: .appleLossless, bitDepth: 16)
        let mp3 = MediaInfo(container: .mp3, codec: .mp3)

        #expect(try ImportPlanner.plan(for: wav, wavFormat: plainWAV, settings: toLossless).action == .convert(.appleLossless))
        #expect(try ImportPlanner.plan(for: lossless, settings: toLossless).action == .copy)
        #expect(try ImportPlanner.plan(for: wav, wavFormat: plainWAV, settings: toAAC).action == .convert(.aac(bitrate: 192_000)))
        #expect(try ImportPlanner.plan(for: lossless, settings: toAAC).action == .convert(.aac(bitrate: 192_000)))
        #expect(try ImportPlanner.plan(for: mp3, settings: toAAC).action == .copy)
    }

    @Test("Copy-protected purchases are refused with an explanation")
    func protectedContent() {
        let info = MediaInfo(container: .mpeg4, codec: .aac, isProtected: true)
        #expect(throws: ImportError.protectedContent) { try ImportPlanner.plan(for: info) }
    }
}
