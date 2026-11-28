// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import NaturalLanguage

/// Chooses the language to speak a title in.
///
/// Titles are short, and unconstrained language detection is unreliable on short text
/// ("Bohemian Rhapsody" comes out Italian, "Road Trip" Indonesian). So detection is boxed in:
/// the writing system decides first, and only languages the user enabled compete after that,
/// with the default language favoured.
public enum LanguageDetector {
    /// - Parameters:
    ///   - defaultLanguage: BCP-47 tag used unless there is good reason to pick another.
    ///   - candidates: other languages that may be chosen.
    ///   - installed: languages that have a voice. When the text is in a script none of the
    ///     enabled languages uses, one of these is picked so that it is still spoken sensibly.
    public static func language(
        for text: String, default defaultLanguage: String, candidates: [String], installed: [String] = []
    ) -> String {
        var enabled = [defaultLanguage]
        for candidate in candidates where !enabled.contains(candidate) { enabled.append(candidate) }

        guard let script = dominantScript(of: text) else { return defaultLanguage }

        if script != .latin {
            let fitting = enabled.filter { script.languages.contains(base($0)) }
            if fitting.count == 1 { return fitting[0] }
            if fitting.count > 1 { return recognize(text, among: fitting, favouring: fitting[0], threshold: 0) }
            // Nothing enabled can read this script. Prefer any installed voice that can over mispronouncing it.
            for language in script.languages {
                if let match = installed.first(where: { base($0) == language }) { return match }
            }
            return defaultLanguage
        }

        let latin = enabled.filter { !Script.nonLatinLanguages.contains(base($0)) }
        guard latin.count > 1 else { return latin.first ?? defaultLanguage }
        let fallback = latin.contains(defaultLanguage) ? defaultLanguage : latin[0]
        return recognize(text, among: latin, favouring: fallback, threshold: 0.6)
    }

    // MARK: Scripts

    enum Script: CaseIterable {
        case latin, cyrillic, greek, kana, han, hangul, arabic, hebrew, thai, devanagari

        /// Language codes written in this script, most likely first.
        var languages: [String] {
            switch self {
            case .latin: return []
            case .cyrillic: return ["ru", "uk", "bg", "sr", "mk", "be", "kk"]
            case .greek: return ["el"]
            case .kana: return ["ja"]
            case .han: return ["zh", "yue", "ja"]
            case .hangul: return ["ko"]
            case .arabic: return ["ar", "fa", "ur"]
            case .hebrew: return ["he"]
            case .thai: return ["th"]
            case .devanagari: return ["hi", "mr", "ne"]
            }
        }

        static let nonLatinLanguages: Set<String> = Set(Script.allCases.flatMap(\.languages))

        init?(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: self = .latin
            case 0x0400...0x052F: self = .cyrillic
            case 0x0370...0x03FF, 0x1F00...0x1FFF: self = .greek
            case 0x3040...0x30FF: self = .kana
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: self = .han
            case 0xAC00...0xD7AF, 0x1100...0x11FF: self = .hangul
            case 0x0600...0x06FF, 0x0750...0x077F: self = .arabic
            case 0x0590...0x05FF: self = .hebrew
            case 0x0E00...0x0E7F: self = .thai
            case 0x0900...0x097F: self = .devanagari
            default: return nil
            }
        }
    }

    /// The script most letters are in, or `nil` when the text has no letters (numbers, symbols).
    static func dominantScript(of text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if let script = Script(scalar) { counts[script, default: 0] += 1 }
        }
        // Japanese mixes kana with Chinese characters; any kana at all means Japanese.
        if let kana = counts[.kana], kana > 0 { return .kana }
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: Statistical detection

    private static func recognize(_ text: String, among languages: [String], favouring fallback: String, threshold: Double) -> String {
        var tagByCode: [NLLanguage: String] = [:]
        for language in languages {
            if let code = code(for: language), tagByCode[code] == nil { tagByCode[code] = language }
        }
        guard tagByCode.count > 1 else { return fallback }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Array(tagByCode.keys)
        let others = Double(max(tagByCode.count - 1, 1))
        var hints: [NLLanguage: Double] = [:]
        for (code, tag) in tagByCode { hints[code] = tag == fallback ? 0.7 : 0.3 / others }
        recognizer.languageHints = hints
        recognizer.processString(text)

        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, let tag = tagByCode[best.key] else { return fallback }
        return tag == fallback || best.value >= threshold ? tag : fallback
    }

    private static func base(_ tag: String) -> String {
        String(tag.split(separator: "-").first ?? Substring(tag)).lowercased()
    }

    private static func code(for tag: String) -> NLLanguage? {
        switch base(tag) {
        case "zh": return .simplifiedChinese
        case "yue": return nil
        case "nb", "no": return .norwegian
        case let other: return NLLanguage(rawValue: other)
        }
    }
}
