// SPDX-FileCopyrightText: 2026 billiamdan
// SPDX-License-Identifier: GPL-2.0-or-later

import ShuffleKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            VoiceOverSettingsView()
                .tabItem { Label("VoiceOver", systemImage: "waveform") }
            ImportSettingsView()
                .tabItem { Label("Adding Music", systemImage: "square.and.arrow.down") }
        }
        .frame(width: 540)
    }
}

private struct VoiceOverSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var voices: [VoiceInfo] = []

    var body: some View {
        @Bindable var model = model
        let language = model.voiceSettings.defaultLanguage

        Form {
            Section {
                Picker("Speak in", selection: $model.voiceSettings.defaultLanguage) {
                    ForEach(model.voiceSettings.installedLanguages, id: \.self) { language in
                        Text(Format.language(language)).tag(language)
                    }
                }
                Picker("Voice", selection: Binding(
                    get: { model.voiceSettings.voiceByLanguage[language] ?? "" },
                    set: { model.voiceSettings.voiceByLanguage[language] = $0.isEmpty ? nil : $0 }
                )) {
                    Text(defaultVoiceLabel(for: language)).tag("")
                    Divider()
                    ForEach(voices.filter { $0.language == language }) { voice in
                        Text(voice.quality > 1 ? "\(voice.name) (enhanced)" : voice.name).tag(voice.id)
                    }
                }
                Toggle("Say the artist after the title", isOn: $model.voiceSettings.speakArtist)
            } footer: {
                Text("More voices can be downloaded in System Settings ▸ Accessibility ▸ Spoken Content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                List(model.voiceSettings.installedLanguages.filter { $0 != language }, id: \.self) { other in
                    Toggle(Format.language(other), isOn: Binding(
                        get: { model.voiceSettings.additionalLanguages.contains(other) },
                        set: { enabled in
                            model.voiceSettings.additionalLanguages.removeAll { $0 == other }
                            if enabled { model.voiceSettings.additionalLanguages.append(other) }
                        }
                    ))
                }
                .frame(height: 170)
            } header: {
                Text("Also speak titles written in")
            } footer: {
                Text("A title is spoken in one of these only when it is clearly written in that language. Titles in another alphabet (for example Cyrillic) use a matching voice automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { voices = SystemSpeech.voices() }
    }

    private func defaultVoiceLabel(for language: String) -> String {
        guard let voice = SystemSpeech.defaultVoice(for: language) else { return "System default" }
        return "System default (\(voice.name))"
    }
}

private struct ImportSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("WAV, AIFF, FLAC and Apple Lossless", selection: $model.importSettings.lossless) {
                    Text("Keep the format").tag(LosslessPolicy.keep)
                    Text("Store as Apple Lossless").tag(LosslessPolicy.appleLossless)
                    Text("Convert to AAC").tag(LosslessPolicy.aac)
                }
                .pickerStyle(.radioGroup)
                if model.importSettings.lossless == .aac {
                    Picker("AAC quality", selection: $model.importSettings.aacBitrate) {
                        Text("128 kbps").tag(128_000)
                        Text("192 kbps").tag(192_000)
                        Text("256 kbps").tag(256_000)
                        Text("320 kbps").tag(320_000)
                    }
                }
            } footer: {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Always copied as they are", value: "MP3, AAC")
                LabeledContent("Always converted", value: "Anything above 16-bit / 48 kHz")
            }
        }
        .formStyle(.grouped)
    }

    private var explanation: String {
        switch model.importSettings.lossless {
        case .keep:
            return "WAV stays WAV and Apple Lossless stays Apple Lossless. AIFF is stored as WAV and FLAC as Apple Lossless, because the iPod plays those. Nothing loses quality."
        case .appleLossless:
            return "Uncompressed and lossless music is stored as Apple Lossless: identical sound in roughly half the space of WAV."
        case .aac:
            return "Uncompressed and lossless music is converted to AAC. It takes a fraction of the space, which matters on a 2 GB player, but it is no longer lossless."
        }
    }
}
