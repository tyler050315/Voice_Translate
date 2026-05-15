import AVFoundation
import Foundation

@MainActor
final class AudioMonitor: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isVoiceDetected = false
    @Published private(set) var level: Float = 0
    @Published var statusText = "Tap the voice button to start."
    @Published var testResultText: String?

    private let engine = AVAudioEngine()
    private var maxDurationTask: Task<Void, Never>?
    private var recordingFile: AVAudioFile?
    private var recordingConverter: AVAudioConverter?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var translationContext: TranslationContext?
    private var smoothedLevel: Float = 0
    private var noiseFloor: Float = 0.006
    private var calibrationSampleCount = 0
    private var lastSpeechAt: Date?
    private let minimumVoiceThreshold: Float = 0.009
    private let farFieldVoiceThreshold: Float = 0.0065
    private let speechThresholdMultiplier: Float = 1.9
    private let maxRecordingDuration: Duration = .seconds(30)
    private let recordingSampleRate = 16_000.0
    private let recordingChannelCount: AVAudioChannelCount = 1
    private let recordingBitRate = 32_000

    func updateTranslationSettings(
        apiKey: String,
        baseURL: String,
        language1: TranslationLanguage,
        language2: TranslationLanguage
    ) {
        translationContext = TranslationContext(
            apiKey: apiKey,
            baseURL: baseURL,
            language1: language1,
            language2: language2
        )
    }

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    func startListening() {
        guard !isListening else { return }

        let onPermissionResult: (Bool) -> Void = { [weak self] granted in
            Task { @MainActor in
                self?.handlePermissionResult(granted)
            }
        }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: onPermissionResult)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(onPermissionResult)
        }
    }

    private func handlePermissionResult(_ granted: Bool) {
        if granted {
            configureAndStartEngine()
        } else {
            statusText = "Microphone permission is required."
        }
    }

    func stopListening() {
        if isRecording {
            finishRecording(reason: "manually finished")
            return
        }

        if isListening {
            finishWithoutRecording()
            return
        }

        resetAudioState()
        statusText = "Tap the voice button to start."
    }

    private func resetAudioState() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        isListening = false
        isRecording = false
        isProcessing = false
        isVoiceDetected = false
        level = 0
        recordingFile = nil
        recordingConverter = nil
        recordingURL = nil
        recordingStartedAt = nil
        resetVoiceDetectionState()
    }

    private func configureAndStartEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            engine.reset()

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                let rms = Self.rootMeanSquarePower(from: buffer)
                Task { @MainActor in
                    self?.handleAudioBuffer(buffer, rms: rms, format: format)
                }
            }

            engine.prepare()
            try engine.start()
            isListening = true
            isProcessing = false
            testResultText = nil
            resetVoiceDetectionState()
            statusText = "Listening for speech..."
        } catch {
            statusText = "Could not start microphone."
            isListening = false
            isVoiceDetected = false
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, rms: Float, format: AVAudioFormat) {
        smoothedLevel = smoothedLevel == 0 ? rms : (smoothedLevel * 0.62 + rms * 0.38)
        level = min(max(max(smoothedLevel, rms) * 30, 0), 1)
        let currentSpeechThreshold = speechThreshold
        let detected = smoothedLevel > currentSpeechThreshold || rms > farFieldTriggerThreshold

        if detected {
            isVoiceDetected = true
            lastSpeechAt = Date()
            startRecordingIfNeeded(format: format)
            writeBuffer(buffer)
            statusText = "Recording..."
        } else if isRecording {
            writeBuffer(buffer)
            isVoiceDetected = false
            statusText = "Recording..."
        } else if isListening {
            updateNoiseEstimate(with: rms, currentSpeechThreshold: currentSpeechThreshold)
            isVoiceDetected = false
            statusText = "Listening for speech..."
        }
    }

    private var speechThreshold: Float {
        max(minimumVoiceThreshold, noiseFloor * speechThresholdMultiplier)
    }

    private var farFieldTriggerThreshold: Float {
        max(farFieldVoiceThreshold, noiseFloor * 1.35)
    }

    private func updateNoiseEstimate(with rms: Float, currentSpeechThreshold: Float) {
        guard !isRecording, calibrationSampleCount < 40 else { return }
        guard rms < currentSpeechThreshold * 0.75 else { return }

        calibrationSampleCount += 1
        noiseFloor = noiseFloor * 0.9 + rms * 0.1
    }

    private func startRecordingIfNeeded(format: AVAudioFormat) {
        guard !isRecording else { return }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-utterance-\(Int(Date().timeIntervalSince1970)).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: recordingSampleRate,
                AVNumberOfChannelsKey: Int(recordingChannelCount),
                AVEncoderBitRateKey: recordingBitRate
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            recordingFile = file
            if !Self.canWriteBuffer(format, directlyTo: file.processingFormat) {
                guard let converter = AVAudioConverter(from: format, to: file.processingFormat) else {
                    throw NSError(domain: "AudioMonitor", code: 2)
                }
                recordingConverter = converter
            }
            recordingURL = url
            recordingStartedAt = Date()
            lastSpeechAt = Date()
            isRecording = true
            isVoiceDetected = true

            maxDurationTask?.cancel()
            let maxRecordingDuration = maxRecordingDuration
            maxDurationTask = Task { [weak self] in
                try? await Task.sleep(for: maxRecordingDuration)
                await self?.finishRecording(reason: "maximum duration reached")
            }
        } catch {
            statusText = "Could not create recording."
            stopListening()
        }
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let recordingFile else { return }

        do {
            if let recordingConverter {
                guard let convertedBuffer = try Self.convert(buffer, with: recordingConverter, to: recordingFile.processingFormat) else {
                    return
                }
                try recordingFile.write(from: convertedBuffer)
            } else {
                try recordingFile.write(from: buffer)
            }
        } catch {
            statusText = "Could not write recording."
            stopListening()
        }
    }

    private func finishRecording(reason: String) {
        guard isRecording else { return }

        let finishedURL = recordingURL
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let finalNoiseFloor = noiseFloor
        let finalSpeechThreshold = speechThreshold
        let finalFarFieldThreshold = farFieldTriggerThreshold
        maxDurationTask?.cancel()
        maxDurationTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        recordingFile = nil
        recordingConverter = nil
        recordingURL = nil
        recordingStartedAt = nil
        lastSpeechAt = nil
        isListening = false
        isRecording = false
        isVoiceDetected = false
        isProcessing = true
        level = 0
        statusText = "Processing..."

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                self?.statusText = "Translating..."
            }

            await self?.translateFinishedRecording(
                url: finishedURL,
                duration: duration,
                reason: reason,
                noiseFloor: finalNoiseFloor,
                speechThreshold: finalSpeechThreshold,
                farFieldThreshold: finalFarFieldThreshold
            )
        }
    }

    private func translateFinishedRecording(
        url: URL?,
        duration: TimeInterval,
        reason: String,
        noiseFloor: Float,
        speechThreshold: Float,
        farFieldThreshold: Float
    ) async {
        guard let url else {
            await MainActor.run {
                completeTestResult(
                    url: nil,
                    duration: duration,
                    reason: reason,
                    noiseFloor: noiseFloor,
                    speechThreshold: speechThreshold,
                    farFieldThreshold: farFieldThreshold
                )
            }
            return
        }

        guard let context = translationContext else {
            await MainActor.run {
                testResultText = "Missing translation settings."
                isProcessing = false
                statusText = "Tap the voice button to start."
            }
            return
        }

        do {
            let service = try OpenAIService(apiKey: context.apiKey, baseURL: context.baseURL)
            let result = try await service.translateAudio(at: url, context: context)
            await MainActor.run {
                completeTranslationResult(result)
            }
        } catch {
            await MainActor.run {
                completeErrorResult(error)
            }
        }
    }

    private func finishWithoutRecording() {
        resetAudioState()
        testResultText = """
        No speech was captured.

        Tap Start Speaking, begin talking, then tap Finish Recording when you are done.
        """
        statusText = "Tap the voice button to start."
    }

    private func completeTranslationResult(_ result: TranslationResult) {
        testResultText = """
        \(result.translatedText)

        Source: \(result.sourceLanguage)
        Target: \(result.targetLanguage)

        Original:
        \(result.transcript)
        """
        isProcessing = false
        statusText = "Tap the voice button to start."
    }

    private func completeErrorResult(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        testResultText = """
        Translation failed

        \(message)
        """
        isProcessing = false
        statusText = "Tap the voice button to start."
    }

    private func completeTestResult(
        url: URL?,
        duration: TimeInterval,
        reason: String,
        noiseFloor: Float,
        speechThreshold: Float,
        farFieldThreshold: Float
    ) {
        let fileName = url?.lastPathComponent ?? "no file"
        let roundedDuration = String(format: "%.1f", max(duration, 0))
        let roundedNoiseFloor = String(format: "%.4f", noiseFloor)
        let roundedSpeechThreshold = String(format: "%.4f", speechThreshold)
        let roundedFarFieldThreshold = String(format: "%.4f", farFieldThreshold)
        testResultText = """
        Test capture completed.

        Recording duration: \(roundedDuration)s
        Stop reason: \(reason)
        Noise floor: \(roundedNoiseFloor)
        Speech threshold: \(roundedSpeechThreshold)
        Far-field threshold: \(roundedFarFieldThreshold)
        Audio file: \(fileName)

        Next step: send this audio clip to the AI API for speech recognition and translation.
        """
        isProcessing = false
        statusText = "Tap the voice button to start."
    }

    private func resetVoiceDetectionState() {
        smoothedLevel = 0
        noiseFloor = 0.006
        calibrationSampleCount = 0
        lastSpeechAt = nil
    }

    nonisolated private static func rootMeanSquarePower(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = channelData[index]
            sum += sample * sample
        }

        return sqrt(sum / Float(frameLength))
    }

    nonisolated private static func canWriteBuffer(_ sourceFormat: AVAudioFormat, directlyTo destinationFormat: AVAudioFormat) -> Bool {
        sourceFormat.sampleRate == destinationFormat.sampleRate
            && sourceFormat.channelCount == destinationFormat.channelCount
            && sourceFormat.commonFormat == destinationFormat.commonFormat
            && sourceFormat.isInterleaved == destinationFormat.isInterleaved
    }

    nonisolated private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        let sampleRateRatio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = max(1, AVAudioFrameCount(ceil(Double(buffer.frameLength) * sampleRateRatio)) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw NSError(domain: "AudioMonitor", code: 1)
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if didProvideInput {
                outputStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outputStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status != .error, outputBuffer.frameLength > 0 else {
            return nil
        }

        return outputBuffer
    }
}
