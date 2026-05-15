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
    }
}

private struct MainView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var audioMonitor = AudioMonitor()
    @State private var translatedText = "Translation text will appear here after speech is processed."

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                languagePairView

                translatedTextBox

                microphoneIndicator

                Text(audioMonitor.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(height: 22)

                Button {
                    audioMonitor.toggleListening()
                } label: {
                    Label(audioMonitor.isListening ? "Stop Listening" : "Start Speaking", systemImage: audioMonitor.isListening ? "stop.fill" : "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
            .navigationTitle("Voice Translate")
            .background(Color(.systemGroupedBackground))
        }
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
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var translatedTextBox: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(translatedText)
                .font(.title2)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        }
    }

    private var microphoneIndicator: some View {
        ZStack {
            Circle()
                .fill(audioMonitor.isVoiceDetected ? Color.green.opacity(0.2) : Color(.tertiarySystemFill))
                .frame(width: 110, height: 110)
                .scaleEffect(audioMonitor.isVoiceDetected ? 1.12 : 1)
                .animation(.easeInOut(duration: 0.22).repeatCount(audioMonitor.isVoiceDetected ? 2 : 1, autoreverses: true), value: audioMonitor.isVoiceDetected)

            Image(systemName: "mic.fill")
                .font(.system(size: 46, weight: .semibold))
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
    @State private var apiKey = ""
    @State private var saveMessage = ""

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

                Section("AI API Key") {
                    SecureField("Enter API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                            .foregroundStyle(language1ID == language2ID ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                language1ID = settings.language1ID
                language2ID = settings.language2ID
                apiKey = settings.apiKey
            }
        }
    }

    private func saveSettings() {
        guard language1ID != language2ID else {
            saveMessage = "Please choose two different languages."
            return
        }

        settings.save(
            language1ID: language1ID,
            language2ID: language2ID,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        saveMessage = "Saved."
    }
}

#Preview {
    ContentView()
}
