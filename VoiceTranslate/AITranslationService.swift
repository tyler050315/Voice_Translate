import Foundation

struct TranslationContext {
    let zhipuAPIKey: String
    let language1: TranslationLanguage
    let language2: TranslationLanguage
}

struct TranslationResult {
    let transcript: String
    let sourceLanguage: String
    let targetLanguage: String
    let targetLanguageID: String
    let translatedText: String
}

enum AITranslationServiceError: LocalizedError {
    case missingZhipuAPIKey
    case invalidResponse
    case requestFailed(provider: String, statusCode: Int, message: String, code: String?)
    case requestTimedOut(provider: String)
    case transportFailed(provider: String, message: String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingZhipuAPIKey:
            return "Please enter and save your Zhipu API key in Settings."
        case .invalidResponse:
            return "The AI service returned an unexpected response."
        case .requestFailed(let provider, let statusCode, let message, let code):
            if code == "insufficient_quota" || message.localizedCaseInsensitiveContains("quota") {
                return "\(provider) quota exceeded. Please check the API key account's billing plan and available credits."
            }

            if statusCode == 503 || message.localizedCaseInsensitiveContains("overloaded") {
                return "\(provider) is temporarily overloaded. Please try again in a moment."
            }

            return "\(provider) request failed (\(statusCode)): \(message)"
        case .requestTimedOut(let provider):
            return "\(provider) request timed out. Please check the network connection and try again."
        case .transportFailed(let provider, let message):
            return "\(provider) network request failed: \(message)"
        case .emptyTranscript:
            return "No speech text was recognized from the recording."
        }
    }
}

private extension AITranslationServiceError {
    var isRetryable: Bool {
        switch self {
        case .requestFailed(_, let statusCode, _, _):
            return statusCode == 429 || statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
        case .requestTimedOut, .transportFailed:
            return true
        case .missingZhipuAPIKey, .invalidResponse, .emptyTranscript:
            return false
        }
    }
}

final class AITranslationService {
    private let zhipuAPIKey: String
    private let session: URLSession

    init(zhipuAPIKey: String, session: URLSession = .shared) {
        self.zhipuAPIKey = zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func translateAudio(at audioURL: URL, context: TranslationContext) async throws -> TranslationResult {
        let transcript = try await transcribeAudioWithZhipu(at: audioURL)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationServiceError.emptyTranscript
        }

        return try await translateTranscriptWithZhipu(transcript, context: context)
    }

    private func transcribeAudioWithZhipu(at audioURL: URL) async throws -> String {
        guard !zhipuAPIKey.isEmpty else { throw AITranslationServiceError.missingZhipuAPIKey }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(zhipuAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeMultipartBody(
            boundary: boundary,
            fields: [
                "model": "glm-asr-2512",
                "stream": "false"
            ],
            fileURL: audioURL,
            fileFieldName: "file",
            mimeType: "audio/wav"
        )

        let data = try await send(request, provider: "Zhipu ASR")
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return response.text
    }

    private func translateTranscriptWithZhipu(_ transcript: String, context: TranslationContext) async throws -> TranslationResult {
        guard !zhipuAPIKey.isEmpty else { throw AITranslationServiceError.missingZhipuAPIKey }

        var request = URLRequest(url: URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(zhipuAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemMessage = """
        You are a speech translation engine. The user configured two languages:
        language1: \(context.language1.name) (\(context.language1.id))
        language2: \(context.language2.name) (\(context.language2.id))

        Decide whether the transcript is closer to language1 or language2, then translate it into the other language.
        Return only compact JSON with keys: source_language, target_language, translation.
        For source_language and target_language, use exactly one configured language id such as \(context.language1.id) or \(context.language2.id).
        """

        let payload = ChatCompletionRequest(
            model: "glm-5.1",
            temperature: 0,
            responseFormat: ResponseFormat(type: "json_object"),
            thinking: Thinking(type: "disabled"),
            stream: false,
            messages: [
                ChatMessage(role: "system", content: systemMessage),
                ChatMessage(role: "user", content: transcript)
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await send(request, provider: "Zhipu translation")
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = response.choices.first?.message.content.data(using: .utf8) else {
            throw AITranslationServiceError.invalidResponse
        }

        let translated = try JSONDecoder().decode(TranslationPayload.self, from: content)
        let targetLanguageID = Self.languageID(for: translated.targetLanguage, context: context)
        return TranslationResult(
            transcript: transcript,
            sourceLanguage: translated.sourceLanguage,
            targetLanguage: translated.targetLanguage,
            targetLanguageID: targetLanguageID,
            translatedText: translated.translation
        )
    }

    private static func languageID(for value: String, context: TranslationContext) -> String {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let language1Matches = [
            context.language1.id.lowercased(),
            context.language1.name.lowercased(),
            context.language1.displayName.lowercased()
        ]
        let language2Matches = [
            context.language2.id.lowercased(),
            context.language2.name.lowercased(),
            context.language2.displayName.lowercased()
        ]

        if language1Matches.contains(normalizedValue) {
            return context.language1.id
        }

        if language2Matches.contains(normalizedValue) {
            return context.language2.id
        }

        return context.language2.id
    }

    private func send(_ request: URLRequest, provider: String) async throws -> Data {
        let maxAttempts = 2
        var lastError: AITranslationServiceError?

        for attempt in 1...maxAttempts {
            do {
                return try await sendOnce(request, provider: provider)
            } catch let error as AITranslationServiceError {
                lastError = error

                if attempt < maxAttempts, error.isRetryable {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                throw error
            }
        }

        throw lastError ?? AITranslationServiceError.invalidResponse
    }

    private func sendOnce(_ request: URLRequest, provider: String) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw AITranslationServiceError.requestTimedOut(provider: provider)
            }

            throw AITranslationServiceError.transportFailed(provider: provider, message: error.localizedDescription)
        } catch {
            throw AITranslationServiceError.transportFailed(provider: provider, message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AITranslationServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw AITranslationServiceError.requestFailed(
                    provider: provider,
                    statusCode: httpResponse.statusCode,
                    message: apiError.error.message,
                    code: apiError.error.code
                )
            }

            let message = String(data: data, encoding: .utf8) ?? "Request failed."
            throw AITranslationServiceError.requestFailed(
                provider: provider,
                statusCode: httpResponse.statusCode,
                message: message,
                code: nil
            )
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
    let thinking: Thinking
    let stream: Bool
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case responseFormat = "response_format"
        case thinking
        case stream
        case messages
    }
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct Thinking: Encodable {
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

private struct APIErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
