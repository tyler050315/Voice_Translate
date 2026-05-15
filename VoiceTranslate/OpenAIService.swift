import Foundation

struct TranslationContext {
    let apiKey: String
    let language1: TranslationLanguage
    let language2: TranslationLanguage
}

struct TranslationResult {
    let transcript: String
    let sourceLanguage: String
    let targetLanguage: String
    let translatedText: String
}

enum OpenAIServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Please enter and save your AI API key in Settings."
        case .invalidResponse:
            return "The AI service returned an unexpected response."
        case .requestFailed(let message):
            return message
        case .emptyTranscript:
            return "No speech text was recognized from the recording."
        }
    }
}

final class OpenAIService {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func translateAudio(at audioURL: URL, context: TranslationContext) async throws -> TranslationResult {
        guard !apiKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        let transcript = try await transcribeAudio(at: audioURL)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIServiceError.emptyTranscript
        }

        return try await translateTranscript(transcript, context: context)
    }

    private func transcribeAudio(at audioURL: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeMultipartBody(
            boundary: boundary,
            fields: [
                "model": "gpt-4o-mini-transcribe",
                "response_format": "json"
            ],
            fileURL: audioURL,
            fileFieldName: "file",
            mimeType: "audio/wav"
        )

        let data = try await send(request)
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return response.text
    }

    private func translateTranscript(_ transcript: String, context: TranslationContext) async throws -> TranslationResult {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemMessage = """
        You are a speech translation engine. The user configured two languages:
        language1: \(context.language1.name) (\(context.language1.id))
        language2: \(context.language2.name) (\(context.language2.id))

        Decide whether the transcript is closer to language1 or language2, then translate it into the other language.
        Return only compact JSON with keys: source_language, target_language, translation.
        """

        let payload = ChatCompletionRequest(
            model: "gpt-4.1-mini",
            temperature: 0,
            responseFormat: ResponseFormat(type: "json_object"),
            messages: [
                ChatMessage(role: "system", content: systemMessage),
                ChatMessage(role: "user", content: transcript)
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await send(request)
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = response.choices.first?.message.content.data(using: .utf8) else {
            throw OpenAIServiceError.invalidResponse
        }

        let translated = try JSONDecoder().decode(TranslationPayload.self, from: content)
        return TranslationResult(
            transcript: transcript,
            sourceLanguage: translated.sourceLanguage,
            targetLanguage: translated.targetLanguage,
            translatedText: translated.translation
        )
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Request failed with status \(httpResponse.statusCode)."
            throw OpenAIServiceError.requestFailed(message)
        }

        return data
    }

    private func makeMultipartBody(
        boundary: String,
        fields: [String: String],
        fileURL: URL,
        fileFieldName: String,
        mimeType: String
    ) throws -> Data {
        var body = Data()

        for (name, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        let fileName = fileURL.lastPathComponent
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        return body
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let temperature: Int
    let responseFormat: ResponseFormat
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case responseFormat = "response_format"
        case messages
    }
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct TranslationPayload: Decodable {
    let sourceLanguage: String
    let targetLanguage: String
    let translation: String

    enum CodingKeys: String, CodingKey {
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
        case translation
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
