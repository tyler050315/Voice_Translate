import Combine
import AVFoundation
import Foundation
import SwiftUI
import UIKit

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
    @State private var autoSpeechTask: Task<Void, Never>?
    @State private var isShowingExportOptions = false
    @State private var shareItem: ShareItem?

    var body: some View {
        VStack(spacing: 12) {
            titleView

            languagePairView

            translatedTextBox

            Text(audioMonitor.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(height: 18)

            Button {
                autoSpeechTask?.cancel()
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
            autoSpeechTask?.cancel()
            if let result {
                speechText = result.translatedText
                speechLanguageID = result.targetLanguageID
                if settings.speechPlaybackMode == .automatic {
                    autoSpeechTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        speechPlayer.speak(result.translatedText, languageID: result.targetLanguageID)
                    }
                }
            } else {
                autoSpeechTask = nil
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
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                translationContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
                    .padding(.top, hasTranslation ? 38 : 0)
                    .padding(.bottom, 66)
            }

            if hasTranslation {
                VStack {
                    HStack {
                        Spacer()

                        Button {
                            isShowingExportOptions = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Circle())
                        .accessibilityLabel("Export translation text")
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 12)

                    Spacer()
                }
            }

            VStack {
                Spacer()

                HStack {
                    microphoneIndicator

                    Spacer()

                    if hasSpeechText {
                        Button {
                            autoSpeechTask?.cancel()
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
                        .accessibilityLabel(speechPlayer.isSpeaking ? "Stop speaking translation" : "Speak translation")
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 430, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        }
        .layoutPriority(1)
        .confirmationDialog("Export Text", isPresented: $isShowingExportOptions, titleVisibility: .visible) {
            Button("Export All") {
                export(.all)
            }

            Button("Export Original") {
                export(.original)
            }

            Button("Export Translation") {
                export(.translation)
            }

            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.text])
        }
    }

    private var hasSpeechText: Bool {
        !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTranslation: Bool {
        audioMonitor.latestTranslation != nil
    }

    @ViewBuilder
    private var translationContent: some View {
        if let translation = audioMonitor.latestTranslation {
            VStack(alignment: .leading, spacing: 16) {
                Text(translation.translatedText)
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.03, green: 0.18, blue: 0.42))
                    .lineSpacing(6)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Source: \(translation.sourceLanguage)")
                    Text("Target: \(translation.targetLanguage)")
                    Text("Original:")
                    Text(translation.transcript)
                }
                .font(.body)
                .foregroundStyle(Color(.systemGray))
                .lineSpacing(4)
            }
        } else {
            Text(translatedText)
                .font(.title2)
                .lineSpacing(6)
                .foregroundStyle(.primary)
        }
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

    private func export(_ option: ExportOption) {
        guard let translation = audioMonitor.latestTranslation else { return }

        let text: String
        switch option {
        case .all:
            text = """
            Translation:
            \(translation.translatedText)

            Source: \(translation.sourceLanguage)
            Target: \(translation.targetLanguage)

            Original:
            \(translation.transcript)
            """
        case .original:
            text = translation.transcript
        case .translation:
            text = translation.translatedText
        }

        shareItem = ShareItem(text: text)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var language1ID = ""
    @State private var language2ID = ""
    @State private var zhipuAPIKey = ""
    @State private var speechPlaybackModeID = SpeechPlaybackMode.manual.rawValue
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

                Section("Speech Playback") {
                    Picker("Playback", selection: $speechPlaybackModeID) {
                        ForEach(SpeechPlaybackMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.id)
                        }
                    }
                }

                Section {
                    Button {
                        saveSettings()
                    } label: {
                        Label("Save", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(language1ID == language2ID)
                }

                if !saveMessage.isEmpty {
                    Section {
                        Text(saveMessage)
                            .font(.footnote)
                            .foregroundStyle(saveMessage == "Saved." ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                language1ID = LanguageCatalog.contains(settings.language1ID) ? settings.language1ID : LanguageCatalog.all[0].id
                language2ID = LanguageCatalog.contains(settings.language2ID) ? settings.language2ID : fallbackLanguage2ID(excluding: language1ID)
                zhipuAPIKey = settings.zhipuAPIKey
                speechPlaybackModeID = settings.speechPlaybackModeID
                zhipuAPIKeyError = ""
            }
        }
    }

    private func fallbackLanguage2ID(excluding language1ID: String) -> String {
        LanguageCatalog.all.first { $0.id != language1ID }?.id ?? language1ID
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
            zhipuAPIKey: zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            speechPlaybackModeID: speechPlaybackModeID
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

private enum ExportOption {
    case all
    case original
    case translation
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
