@preconcurrency import AVFoundation
import Foundation

/// A system voice that can be used for announcements.
public struct VoiceInfo: Sendable, Identifiable, Equatable {
    /// The system's voice identifier, e.g. `com.apple.voice.compact.en-GB.Daniel`.
    public var id: String
    public var name: String
    /// BCP-47 tag such as "en-GB".
    public var language: String
    /// 1 standard, 2 enhanced, 3 premium.
    public var quality: Int
}

/// Speech as the iPod wants it: 16-bit mono at 22,050 Hz.
public struct RenderedSpeech: Sendable, Equatable {
    public static let sampleRate = 22050

    public var samples: Data
    public var voiceID: String

    public init(samples: Data, voiceID: String) {
        self.samples = samples
        self.voiceID = voiceID
    }

    public var durationMs: Int { samples.count / 2 * 1000 / RenderedSpeech.sampleRate }

    /// The complete file for `Speakable/Tracks` or `Speakable/Playlists`.
    public var wavFile: Data { WAVFile.file(samples: samples, sampleRate: RenderedSpeech.sampleRate, channels: 1) }
}

public enum SpeechError: ShuffleError, Equatable {
    case nothingToSay
    case noVoice(String)
    case timedOut
    case failed(String)

    public var description: String {
        switch self {
        case .nothingToSay: return "there is nothing to say"
        case let .noVoice(language): return "no system voice is installed for \(language)"
        case .timedOut: return "the speech synthesizer did not respond"
        case let .failed(reason): return "speech synthesis failed: \(reason)"
        }
    }
}

/// Anything that can turn text into announcement audio. The app uses `SystemSpeech`; tests supply their own.
public protocol SpeechProvider: Sendable {
    func render(text: String, voiceID: String?, language: String) async throws -> RenderedSpeech
}

/// Announcements spoken by the voices that ship with macOS.
public struct SystemSpeech: SpeechProvider {
    public init() {}

    public func render(text: String, voiceID: String?, language: String) async throws -> RenderedSpeech {
        try await SpeechRenderer.shared.render(text, voiceID: voiceID, language: language)
    }

    /// Installed voices, best quality first within each language. Novelty and personal voices are left out.
    public static func voices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .map { VoiceInfo(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue) }
            .sorted { ($0.language, -$0.quality, $0.name) < ($1.language, -$1.quality, $1.name) }
    }

    /// Languages that have at least one installed voice, as BCP-47 tags.
    public static func languages() -> [String] {
        Array(Set(voices().map(\.language))).sorted()
    }

    public static func hasVoice(for language: String) -> Bool {
        AVSpeechSynthesisVoice(language: language) != nil
    }

    /// The language the Mac's own speech is set to, e.g. "en-US".
    public static func systemLanguage() -> String {
        AVSpeechSynthesisVoice.currentLanguageCode()
    }

    /// The voice the system would pick for a language, when the user has not chosen one.
    public static func defaultVoice(for language: String) -> VoiceInfo? {
        guard let voice = AVSpeechSynthesisVoice(language: language) else { return nil }
        return VoiceInfo(id: voice.identifier, name: voice.name, language: voice.language, quality: voice.quality.rawValue)
    }
}

/// Drives `AVSpeechSynthesizer` one utterance at a time and collects its output.
@MainActor
final class SpeechRenderer {
    static let shared = SpeechRenderer()

    private let synthesizer = AVSpeechSynthesizer()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func render(_ text: String, voiceID: String?, language: String) async throws -> RenderedSpeech {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechError.nothingToSay }
        guard let voice = voiceID.flatMap({ AVSpeechSynthesisVoice(identifier: $0) }) ?? AVSpeechSynthesisVoice(language: language) else {
            throw SpeechError.noVoice(language)
        }

        await acquire()
        defer { release() }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        let collector = SpeechCollector()
        let synthesizer = self.synthesizer

        let samples: Data = try await withCheckedThrowingContinuation { continuation in
            collector.begin(continuation)
            // The synthesizer calls back on its own queue, so the closure must not be tied to the main actor.
            let callback: @Sendable (AVAudioBuffer) -> Void = { buffer in collector.receive(buffer) }
            synthesizer.write(utterance, toBufferCallback: callback)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if collector.fail(SpeechError.timedOut) { synthesizer.stopSpeaking(at: .immediate) }
            }
        }
        let polished = SpeechPolish.apply(samples)
        guard !polished.isEmpty else { throw SpeechError.nothingToSay }
        return RenderedSpeech(samples: polished, voiceID: voice.identifier)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Receives the synthesizer's audio blocks and converts them to 22,050 Hz 16-bit mono.
private final class SpeechCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = Data()
    private var converter: AVAudioConverter?
    private var continuation: CheckedContinuation<Data, Error>?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(RenderedSpeech.sampleRate), channels: 1, interleaved: true
    )!

    private final class Feed {
        var buffer: AVAudioPCMBuffer?
    }

    func begin(_ continuation: CheckedContinuation<Data, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil else { return }
        do {
            if pcm.frameLength == 0 {
                // An empty block marks the end of the utterance.
                try convert(nil)
                let finished = samples
                let pending = continuation
                continuation = nil
                pending?.resume(returning: finished)
            } else {
                try convert(pcm)
            }
        } catch {
            let pending = continuation
            continuation = nil
            pending?.resume(throwing: SpeechError.failed(error.localizedDescription))
        }
    }

    /// Ends the wait with an error unless the utterance already finished. Returns whether it did anything.
    func fail(_ error: Error) -> Bool {
        let pending: CheckedContinuation<Data, Error>? = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(throwing: error)
        return pending != nil
    }

    /// Converts one block (or flushes the converter when `pcm` is nil) and appends the result.
    private func convert(_ pcm: AVAudioPCMBuffer?) throws {
        if let pcm, pcm.format == target {
            if let pointer = pcm.int16ChannelData?[0] {
                samples.append(Data(bytes: pointer, count: Int(pcm.frameLength) * 2))
            }
            return
        }
        if converter == nil {
            guard let pcm else { return }
            guard let made = AVAudioConverter(from: pcm.format, to: target) else {
                throw SpeechError.failed("unsupported voice format")
            }
            made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = made
        }
        guard let converter else { return }

        let ratio = target.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm?.frameLength ?? 0) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let feed = Feed()
        feed.buffer = pcm
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if let next = feed.buffer {
                feed.buffer = nil
                inputStatus.pointee = .haveData
                return next
            }
            inputStatus.pointee = pcm == nil ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            throw SpeechError.failed(conversionError?.localizedDescription ?? "conversion failed")
        }
        if output.frameLength > 0, let pointer = output.int16ChannelData?[0] {
            samples.append(Data(bytes: pointer, count: Int(output.frameLength) * 2))
        }
    }
}

/// Tidies a rendered clip: trims silence at both ends and brings quiet voices up to a common level,
/// so announcements are audible over music and do not waste space.
enum SpeechPolish {
    private static let silenceThreshold: Int32 = 96
    private static let padding = RenderedSpeech.sampleRate / 20      // keep 50 ms around the speech
    private static let targetPeak: Double = 0.89 * 32767
    private static let maximumGain: Double = 4

    static func apply(_ data: Data) -> Data {
        var samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        guard let first = samples.firstIndex(where: { abs(Int32($0)) > silenceThreshold }),
              let last = samples.lastIndex(where: { abs(Int32($0)) > silenceThreshold }) else { return Data() }
        samples = Array(samples[max(0, first - padding)...min(samples.count - 1, last + padding)])

        let peak = Double(samples.map { abs(Int32($0)) }.max() ?? 0)
        if peak > 0, peak < targetPeak {
            let gain = min(targetPeak / peak, maximumGain)
            samples = samples.map { Int16(max(-32768, min(32767, (Double($0) * gain).rounded()))) }
        }
        var out = Data(capacity: samples.count * 2)
        for sample in samples {
            out.append(UInt8(truncatingIfNeeded: sample))
            out.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return out
    }
}
