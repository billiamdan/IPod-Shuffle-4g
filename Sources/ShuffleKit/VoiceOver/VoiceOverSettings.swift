import Foundation

/// How announcements are worded and voiced. Stored with the app's preferences, not on the iPod.
public struct VoiceOverSettings: Codable, Sendable, Equatable {
    /// BCP-47 tag of the language announcements are normally spoken in.
    public var defaultLanguage: String
    /// Other languages a title may be spoken in when it is clearly written in one of them.
    public var additionalLanguages: [String]
    /// A specific voice per language (voice identifier). Languages not listed use the system's default voice.
    public var voiceByLanguage: [String: String]
    /// Say "title, artist" rather than just the title.
    public var speakArtist: Bool
    /// Languages with an installed voice, used to speak text in a script no enabled language can read.
    public var installedLanguages: [String]

    public init(
        defaultLanguage: String = "en-US", additionalLanguages: [String] = [], voiceByLanguage: [String: String] = [:],
        speakArtist: Bool = true, installedLanguages: [String] = []
    ) {
        self.defaultLanguage = defaultLanguage
        self.additionalLanguages = additionalLanguages
        self.voiceByLanguage = voiceByLanguage
        self.speakArtist = speakArtist
        self.installedLanguages = installedLanguages
    }

    /// Settings matching the Mac: the language its own speech uses, with every installed language as a fallback
    /// for text in other scripts.
    public static func systemDefault() -> VoiceOverSettings {
        let installed = SystemSpeech.languages()
        let system = SystemSpeech.systemLanguage()
        let language = installed.contains(system) ? system : (installed.contains("en-US") ? "en-US" : installed.first ?? "en-US")
        return VoiceOverSettings(defaultLanguage: language, installedLanguages: installed)
    }

    // MARK: Wording

    public func spokenText(for track: Track) -> String {
        if let custom = track.spokenName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        let title = Self.tidy(track.title)
        let artist = Self.tidy(track.artist)
        guard speakArtist, !artist.isEmpty, !title.localizedCaseInsensitiveContains(artist) else { return title }
        return title.isEmpty ? artist : "\(title), \(artist)"
    }

    public func spokenText(for playlist: Playlist) -> String {
        if let custom = playlist.spokenName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        return Self.tidy(playlist.name)
    }

    public func language(for text: String, override: String? = nil) -> String {
        if let override, !override.isEmpty { return override }
        return LanguageDetector.language(
            for: text, default: defaultLanguage, candidates: additionalLanguages, installed: installedLanguages
        )
    }

    public func voiceID(for language: String) -> String? { voiceByLanguage[language] }

    /// Identifies a rendering: when it changes, the recording is out of date.
    func renderKey(language: String) -> String {
        "\(language)|\(voiceID(for: language) ?? "")"
    }

    /// Makes file-name-like titles speakable: underscores and separators become pauses, runs of spaces collapse.
    static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "_", with: " ")
        for separator in [" - ", " – ", " — ", " | "] {
            result = result.replacingOccurrences(of: separator, with: ", ")
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
