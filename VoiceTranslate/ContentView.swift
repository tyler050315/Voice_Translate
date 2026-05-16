import Combine
import AVFoundation
import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()

    var body: some View {
        TabView {
            MainView(settings: settings)
                .tabItem {
                    Label("Translate", systemImage: "mic.circle.fill")
                }

            SettingsView(settings: settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .onAppear {
            NetworkPermissionPrimer.requestAccessIfNeeded()
        }
    }
}

private struct MainView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var audioMonitor = AudioMonitor()
    @StateObject private var speechPlayer = LocalSpeechPlayer()
    @State private var translatedText = "Translation text will appear here after speech is processed."
    @State private var speechText = ""
    @State private var speechLanguageID = ""

    var body: some View {
        VStack(spacing: 12) {
            titleView

            languagePairView

            translatedTextBox

            microphoneIndicator

            Text(audioMonitor.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(height: 18)

            Button {
                speechPlayer.stop()
                audioMonitor.updateTranslationSettings(
                    zhipuAPIKey: settings.zhipuAPIKey,
                    language1: settings.language1,
                    language2: settings.language2
                )
                audioMonitor.toggleListening()
            } label: {
                Label(buttonTitle, systemImage: buttonIconName)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(audioMonitor.isProcessing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            audioMonitor.updateTranslationSettings(
                zhipuAPIKey: settings.zhipuAPIKey,
                language1: settings.language1,
                language2: settings.language2
            )
        }
        .onReceive(audioMonitor.$testResultText.compactMap { $0 }) { result in
            translatedText = result
        }
        .onReceive(audioMonitor.$latestTranslation) { result in
            if let result {
                speechText = result.translatedText
                speechLanguageID = result.targetLanguageID
            } else {
                speechPlayer.stop()
                speechText = ""
                speechLanguageID = ""
            }
        }
    }

    private var buttonTitle: String {
        if audioMonitor.isProcessing {
            return "Processing"
        }

        if audioMonitor.isRecording {
            return "Finish Recording"
        }

        return audioMonitor.isListening ? "Cancel Listening" : "Start Speaking"
    }

    private var buttonIconName: String {
        if audioMonitor.isProcessing {
            return "hourglass"
        }

        return audioMonitor.isListening ? "stop.fill" : "mic.fill"
    }

    private var titleView: some View {
        Text("Voice Translate")
            .font(.custom("HelveticaNeue-CondensedBlack", size: 22, relativeTo: .title3))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private var languagePairView: some View {
        HStack(spacing: 10) {
            languageBadge(settings.language1)
            Image(systemName: "arrow.left.arrow.right")
                .font(.headline)
                .foregroundStyle(.secondary)
            languageBadge(settings.language2)
        }
        .frame(maxWidth: .infinity)
    }

    private func languageBadge(_ language: TranslationLanguage) -> some View {
        VStack(spacing: 2) {
            Text(language.displayName)
                .font(.headline)
            Text(language.id)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var translatedTextBox: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                Text(translatedText)
                    .font(.title2)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
                    .padding(.bottom, hasSpeechText ? 54 : 0)
            }

            if hasSpeechText {
                Button {
                    if speechPlayer.isSpeaking {
                        speechPlayer.stop()
                    } else {
                        speechPlayer.speak(speechText, languageID: speechLanguageID)
                    }
                } label: {
                    Image(systemName: speechPlayer.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .padding(14)
                .accessibilityLabel(speechPlayer.isSpeaking ? "Stop speaking translation" : "Speak translation")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        }
        .layoutPriority(1)
    }

    private var hasSpeechText: Bool {
        !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var microphoneIndicator: some View {
        ZStack {
            Circle()
                .fill(audioMonitor.isVoiceDetected ? Color.green.opacity(0.2) : Color(.tertiarySystemFill))
                .frame(width: 54, height: 54)
                .scaleEffect(audioMonitor.isVoiceDetected ? 1.12 : 1)
                .animation(.easeInOut(duration: 0.22).repeatCount(audioMonitor.isVoiceDetected ? 2 : 1, autoreverses: true), value: audioMonitor.isVoiceDetected)

            Image(systemName: "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(audioMonitor.isListening ? Color.accentColor : Color.secondary)
                .opacity(audioMonitor.isVoiceDetected ? 0.35 + Double(audioMonitor.level) * 0.65 : 0.65)
                .scaleEffect(audioMonitor.isVoiceDetected ? 1.08 : 1)
                .animation(.easeInOut(duration: 0.16), value: audioMonitor.level)
        }
        .accessibilityLabel(audioMonitor.isVoiceDetected ? "Voice detected" : "Microphone idle")
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var language1ID = ""
    @State private var language2ID = ""
    @State private var zhipuAPIKey = ""
    @State private var saveMessage = ""
    @State private var zhipuAPIKeyError = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Languages") {
                    Picker("Language 1", selection: $language1ID) {
                        ForEach(LanguageCatalog.all) { language in
                            Text("\(language.displayName) / \(language.id)").tag(language.id)
                        }
                    }

                    Picker("Language 2", selection: $language2ID) {
                        ForEach(LanguageCatalog.all) { language in
                            Text("\(language.displayName) / \(language.id)").tag(language.id)
                        }
                    }
                }

                Section("Zhipu API Key") {
                    SecureField("Enter Zhipu API key", text: $zhipuAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !zhipuAPIKeyError.isEmpty {
                        Text(zhipuAPIKeyError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("AI Services") {
                    Text("Zhipu GLM-ASR-2512 handles speech recognition. Zhipu GLM-5.1 handles translation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        saveSettings()
                    } label: {
                        Label("Save", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(language1ID == language2ID)

                    if !saveMessage.isEmpty {
                        Text(saveMessage)
                            .font(.footnote)
                            .foregroundStyle(saveMessage == "Saved." ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                language1ID = settings.language1ID
                language2ID = settings.language2ID
                zhipuAPIKey = settings.zhipuAPIKey
                zhipuAPIKeyError = ""
            }
        }
    }

    private func saveSettings() {
        guard language1ID != language2ID else {
            saveMessage = "Please choose two different languages."
            return
        }

        if let validationError = AppSettings.validateAPIKey(zhipuAPIKey) {
            zhipuAPIKeyError = validationError
            saveMessage = validationError
            return
        }

        zhipuAPIKeyError = ""
        settings.save(
            language1ID: language1ID,
            language2ID: language2ID,
            zhipuAPIKey: zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        saveMessage = "Saved."
    }
}

#Preview {
    ContentView()
}

private enum NetworkPermissionPrimer {
    private static var hasRequestedAccess = false

    static func requestAccessIfNeeded() {
        guard !hasRequestedAccess else { return }
        hasRequestedAccess = true

        guard let url = URL(string: "https://open.bigmodel.cn/api/paas/v4/") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "HEAD"

        URLSession.shared.dataTask(with: request).resume()
    }
}

@MainActor
private final class LocalSpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageID: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        stop()
        configureAudioSession()

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = Self.voice(for: languageID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1
        utterance.volume = 1
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    private static func voice(for languageID: String) -> AVSpeechSynthesisVoice? {
        if let exactVoice = AVSpeechSynthesisVoice(language: languageID) {
            return exactVoice
        }

        let languagePrefix = languageID.split(separator: "-").first.map(String.init)
        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            guard let languagePrefix else { return false }
            return voice.language.hasPrefix(languagePrefix)
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Speech can still work with the current audio session; keep playback best-effort.
        }
    }
}
