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

enum AudioRecordingFormat: String, CaseIterable, Identifiable {
    case m4aAAC = "m4a_aac"
    case wav = "wav"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .m4aAAC:
            return "M4A/AAC Fast"
        case .wav:
            return "WAV Compatible"
        }
    }

    var detailText: String {
        switch self {
        case .m4aAAC:
            return "Small upload size, 16 kHz mono, 32 kbps."
        case .wav:
            return "Larger upload size, best compatibility."
        }
    }

    var fileExtension: String {
        switch self {
        case .m4aAAC:
            return "m4a"
        case .wav:
            return "wav"
        }
    }

    var requiresConversion: Bool {
        switch self {
        case .m4aAAC:
            return true
        case .wav:
            return false
        }
    }

    static func format(for id: String) -> AudioRecordingFormat {
        AudioRecordingFormat(rawValue: id) ?? .m4aAAC
    }
}

final class AppSettings: ObservableObject {
    @Published var language1ID: String
    @Published var language2ID: String
    @Published var apiKey: String
    @Published var baseURL: String
    @Published var audioFormatID: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language1ID = defaults.string(forKey: "language1") ?? "zh-CN"
        language2ID = defaults.string(forKey: "language2") ?? "en-US"
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        baseURL = defaults.string(forKey: "baseURL") ?? "https://api.whatai.cc"
        audioFormatID = defaults.string(forKey: "audioFormat") ?? AudioRecordingFormat.m4aAAC.rawValue
    }

    var language1: TranslationLanguage {
        LanguageCatalog.language(for: language1ID)
    }

    var language2: TranslationLanguage {
        LanguageCatalog.language(for: language2ID)
    }

    var audioFormat: AudioRecordingFormat {
        AudioRecordingFormat.format(for: audioFormatID)
    }

    func save(language1ID: String, language2ID: String, apiKey: String, baseURL: String, audioFormatID: String) {
        self.language1ID = language1ID
        self.language2ID = language2ID
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.audioFormatID = audioFormatID

        defaults.set(language1ID, forKey: "language1")
        defaults.set(language2ID, forKey: "language2")
        defaults.set(apiKey, forKey: "apiKey")
        defaults.set(baseURL, forKey: "baseURL")
        defaults.set(audioFormatID, forKey: "audioFormat")
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

    static func validateBaseURL(_ baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return "Please enter a Base URL."
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host != nil else {
            return "Base URL must be a valid https URL."
        }

        return nil
    }
}
