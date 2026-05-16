import Foundation

struct TranslationLanguage: Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String
}

enum LanguageCatalog {
    static let all: [TranslationLanguage] = [
        TranslationLanguage(id: "zh-CN", name: "Chinese", displayName: "Chinese"),
        TranslationLanguage(id: "en-US", name: "English", displayName: "English"),
        TranslationLanguage(id: "ja-JP", name: "Japanese", displayName: "Japanese"),
        TranslationLanguage(id: "ko-KR", name: "Korean", displayName: "Korean"),
        TranslationLanguage(id: "fr-FR", name: "French", displayName: "French"),
        TranslationLanguage(id: "de-DE", name: "German", displayName: "German"),
        TranslationLanguage(id: "es-ES", name: "Spanish", displayName: "Spanish")
    ]

    static func language(for id: String) -> TranslationLanguage {
        all.first { $0.id == id } ?? all[0]
    }
}

enum SpeechPlaybackMode: String, CaseIterable, Identifiable {
    case manual = "manual"
    case automatic = "automatic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual:
            return "Manual Playback"
        case .automatic:
            return "Auto Playback"
        }
    }

    static func mode(for id: String) -> SpeechPlaybackMode {
        SpeechPlaybackMode(rawValue: id) ?? .manual
    }
}

final class AppSettings: ObservableObject {
    @Published var language1ID: String
    @Published var language2ID: String
    @Published var zhipuAPIKey: String
    @Published var speechPlaybackModeID: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language1ID = defaults.string(forKey: "language1") ?? "zh-CN"
        language2ID = defaults.string(forKey: "language2") ?? "en-US"
        zhipuAPIKey = defaults.string(forKey: "zhipuAPIKey") ?? ""
        speechPlaybackModeID = defaults.string(forKey: "speechPlaybackMode") ?? SpeechPlaybackMode.manual.rawValue
    }

    var language1: TranslationLanguage {
        LanguageCatalog.language(for: language1ID)
    }

    var language2: TranslationLanguage {
        LanguageCatalog.language(for: language2ID)
    }

    var speechPlaybackMode: SpeechPlaybackMode {
        SpeechPlaybackMode.mode(for: speechPlaybackModeID)
    }

    func save(language1ID: String, language2ID: String, zhipuAPIKey: String, speechPlaybackModeID: String) {
        self.language1ID = language1ID
        self.language2ID = language2ID
        self.zhipuAPIKey = zhipuAPIKey
        self.speechPlaybackModeID = speechPlaybackModeID

        defaults.set(language1ID, forKey: "language1")
        defaults.set(language2ID, forKey: "language2")
        defaults.set(zhipuAPIKey, forKey: "zhipuAPIKey")
        defaults.set(speechPlaybackModeID, forKey: "speechPlaybackMode")
    }

    static func validateAPIKey(_ apiKey: String) -> String? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return "Please enter an API key."
        }

        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "API key cannot contain spaces or line breaks."
        }

        if trimmed.count < 8 {
            return "API key looks too short."
        }

        return nil
    }
}
