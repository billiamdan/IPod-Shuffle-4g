import Foundation
import Testing
@testable import ShuffleKit

@Suite("Choosing the language of an announcement")
struct LanguageDetectorTests {
    private let enabled = ["ru-RU", "fr-FR", "de-DE", "es-ES"]

    private func detect(_ text: String, candidates: [String]? = nil, installed: [String] = []) -> String {
        LanguageDetector.language(for: text, default: "en-US", candidates: candidates ?? enabled, installed: installed)
    }

    @Test("Short English titles stay English even though unconstrained detection gets them wrong", arguments: [
        "Bohemian Rhapsody - Queen", "Road Trip", "Intro", "Workout Mix", "01 Track",
    ])
    func englishTitles(title: String) {
        #expect(detect(title) == "en-US")
    }

    @Test("Titles clearly in another enabled language are spoken in it")
    func otherLanguages() {
        #expect(detect("Группа крови - Кино") == "ru-RU")
        #expect(detect("Звезда по имени Солнце") == "ru-RU")
        #expect(detect("Ne me quitte pas - Jacques Brel") == "fr-FR")
        #expect(detect("Du hast mich gefragt und ich hab nichts gesagt") == "de-DE")
    }

    @Test("With no other language enabled, everything in Latin script uses the default")
    func onlyDefault() {
        #expect(detect("Ne me quitte pas", candidates: []) == "en-US")
    }

    @Test("Text in a script no enabled language reads falls back to an installed voice for that script")
    func scriptFallback() {
        #expect(detect("Группа крови", candidates: [], installed: ["en-US", "ru-RU"]) == "ru-RU")
        #expect(detect("こんにちは世界", candidates: [], installed: ["ja-JP", "zh-CN"]) == "ja-JP")
        #expect(detect("你好世界", candidates: [], installed: ["ja-JP", "zh-CN"]) == "zh-CN")
        #expect(detect("Группа крови", candidates: [], installed: ["en-US"]) == "en-US")
    }

    @Test("Text without letters uses the default language")
    func noLetters() {
        #expect(detect("1984") == "en-US")
        #expect(detect("") == "en-US")
        #expect(detect("— ! —") == "en-US")
    }
}

@Suite("Wording of announcements")
struct VoiceOverSettingsTests {
    private func track(_ title: String, _ artist: String = "") -> Track {
        Track(record: TrackRecord(id: 1, path: "/x.mp3", fileType: 1), title: title, artist: artist, kind: "MP3")
    }

    @Test("Tracks are announced as title, then artist")
    func titleAndArtist() {
        let settings = VoiceOverSettings()
        #expect(settings.spokenText(for: track("Bohemian Rhapsody", "Queen")) == "Bohemian Rhapsody, Queen")
        #expect(settings.spokenText(for: track("Intro")) == "Intro")
        #expect(VoiceOverSettings(speakArtist: false).spokenText(for: track("Song", "Band")) == "Song")
    }

    @Test("The artist is not repeated when the title already contains it")
    func noRepeatedArtist() {
        let settings = VoiceOverSettings()
        #expect(settings.spokenText(for: track("Nova Kids - Sunset Stage 2018", "Sunset Stage")) == "Nova Kids, Sunset Stage 2018")
    }

    @Test("File-name punctuation becomes pauses")
    func tidiesFileNames() {
        #expect(VoiceOverSettings.tidy("my_mix__final - part 2") == "my mix final, part 2")
        #expect(VoiceOverSettings.tidy("  spaced   out  ") == "spaced out")
    }

    @Test("A custom spoken name and language win over everything else")
    func overrides() {
        var custom = track("Трек", "Группа")
        custom.spokenName = "My favourite"
        let settings = VoiceOverSettings(additionalLanguages: ["ru-RU"])
        #expect(settings.spokenText(for: custom) == "My favourite")
        #expect(settings.language(for: "Трек") == "ru-RU")
        #expect(settings.language(for: "Трек", override: "en-GB") == "en-GB")
    }

    @Test("The render key changes with the language and the chosen voice")
    func renderKeys() {
        var settings = VoiceOverSettings()
        let automatic = settings.renderKey(language: "en-US")
        settings.voiceByLanguage["en-US"] = "com.apple.voice.compact.en-US.Samantha"
        #expect(settings.renderKey(language: "en-US") != automatic)
        #expect(settings.renderKey(language: "ru-RU") != automatic)
    }
}

@Suite("Polishing rendered speech")
struct SpeechPolishTests {
    private func samples(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }

    @Test("Silence at both ends is cut back to a short margin")
    func trimsSilence() {
        let quiet = [Int16](repeating: 0, count: 10_000)
        let voiced = [Int16](repeating: 20_000, count: 3_000)
        let result = SpeechPolish.apply(samples(quiet + voiced + quiet))
        let margin = RenderedSpeech.sampleRate / 20
        #expect(result.count / 2 == 3_000 + 2 * margin)
    }

    @Test("Quiet speech is brought up, but never by more than four times")
    func normalizes() {
        let result = SpeechPolish.apply(samples([Int16](repeating: 5_000, count: 100)))
        let first = Int16(result[0]) | Int16(result[1]) << 8
        #expect(first == 20_000)

        let loud = SpeechPolish.apply(samples([Int16](repeating: 30_000, count: 100)))
        #expect((Int16(loud[0]) | Int16(loud[1]) << 8) == 30_000)
    }

    @Test("A clip that is silent throughout yields nothing")
    func silenceOnly() {
        #expect(SpeechPolish.apply(samples([Int16](repeating: 3, count: 500))).isEmpty)
    }
}

@Suite("System voices", .enabled(if: SystemSpeech.hasVoice(for: "en-US"), "needs an English system voice"))
struct SystemSpeechTests {
    @Test("Text is rendered to the iPod's announcement format")
    func rendersEnglish() async throws {
        let speech = try await SystemSpeech().render(text: "Test playlist", voiceID: nil, language: "en-US")
        #expect(speech.durationMs > 300)
        #expect(speech.durationMs < 5_000)
        #expect(speech.samples.count % 2 == 0)

        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("announcement.wav")
        try speech.wavFile.write(to: url)
        let layout = try WAVFile.inspect(url)
        #expect(layout.format.sampleRate == 22050)
        #expect(layout.format.channels == 1)
        #expect(layout.format.bitsPerSample == 16)
        #expect(layout.dataOffset == 4096)

        // What macOS itself decodes must agree.
        let info = try await MediaProbe.probe(url)
        #expect(info.codec == .pcm)
        #expect(info.sampleRate == 22050)
        #expect(abs(info.durationMs - speech.durationMs) <= 2)
    }

    @Test("Several announcements in a row all complete")
    func rendersSequentially() async throws {
        for text in ["One", "Two", "Three"] {
            let speech = try await SystemSpeech().render(text: text, voiceID: nil, language: "en-US")
            #expect(!speech.samples.isEmpty)
        }
    }

    @Test("Blank text is refused rather than rendered as silence")
    func refusesBlankText() async {
        await #expect(throws: SpeechError.nothingToSay) {
            try await SystemSpeech().render(text: "   ", voiceID: nil, language: "en-US")
        }
    }

    @Test("Installed voices are listed without novelty voices")
    func listsVoices() {
        let voices = SystemSpeech.voices()
        #expect(!voices.isEmpty)
        #expect(!voices.contains { $0.name == "Bad News" || $0.name == "Bells" })
        #expect(SystemSpeech.languages().contains("en-US"))
    }
}
