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
    private var silenceTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private let voiceThreshold: Float = 0.018
    private let silenceTimeout: Duration = .milliseconds(1_200)
    private let maxRecordingDuration: Duration = .seconds(15)

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
        silenceTask?.cancel()
        silenceTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
        isRecording = false
        isProcessing = false
        isVoiceDetected = false
        level = 0
        recordingFile = nil
        recordingURL = nil
        recordingStartedAt = nil
        statusText = "Tap the voice button to start."
    }

    private func configureAndStartEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

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
            statusText = "Listening for speech..."
        } catch {
            statusText = "Could not start microphone."
            isListening = false
            isVoiceDetected = false
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, rms: Float, format: AVAudioFormat) {
        level = min(max(rms * 18, 0), 1)
        let detected = rms > voiceThreshold

        if detected {
            isVoiceDetected = true
            startRecordingIfNeeded(format: format)
            writeBuffer(buffer)
            silenceTask?.cancel()
            silenceTask = nil
            statusText = "Recording..."
        } else if isRecording {
            writeBuffer(buffer)
            scheduleFinishAfterSilence()
        } else if isListening {
            isVoiceDetected = false
            statusText = "Listening for speech..."
        }
    }

    private func startRecordingIfNeeded(format: AVAudioFormat) {
        guard !isRecording else { return }

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-utterance-\(Int(Date().timeIntervalSince1970)).caf")
            recordingFile = try AVAudioFile(forWriting: url, settings: format.settings)
            recordingURL = url
            recordingStartedAt = Date()
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
            try recordingFile.write(from: buffer)
        } catch {
            statusText = "Could not write recording."
            stopListening()
        }
    }

    private func scheduleFinishAfterSilence() {
        guard silenceTask == nil else { return }

        isVoiceDetected = false
        statusText = "Silence detected..."
        let silenceTimeout = silenceTimeout
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: silenceTimeout)
            await self?.finishRecording(reason: "silence detected")
        }
    }

    private func finishRecording(reason: String) {
        guard isRecording else { return }

        let finishedURL = recordingURL
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        silenceTask?.cancel()
        silenceTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recordingFile = nil
        recordingURL = nil
        recordingStartedAt = nil
        isListening = false
        isRecording = false
        isVoiceDetected = false
        isProcessing = true
        level = 0
        statusText = "Processing..."

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                self?.completeTestResult(url: finishedURL, duration: duration, reason: reason)
            }
        }
    }

    private func completeTestResult(url: URL?, duration: TimeInterval, reason: String) {
        let fileName = url?.lastPathComponent ?? "no file"
        let roundedDuration = String(format: "%.1f", max(duration, 0))
        testResultText = """
        Test capture completed.

        Recording duration: \(roundedDuration)s
        Stop reason: \(reason)
        Audio file: \(fileName)

        Next step: send this audio clip to the AI API for speech recognition and translation.
        """
        isProcessing = false
        statusText = "Tap the voice button to start."
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
}
