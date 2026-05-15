import AVFoundation
import Foundation

@MainActor
final class AudioMonitor: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isVoiceDetected = false
    @Published private(set) var level: Float = 0
    @Published var statusText = "Tap the voice button to start."

    private let engine = AVAudioEngine()
    private var silenceTask: Task<Void, Never>?

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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
        isVoiceDetected = false
        level = 0
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
                    self?.handleAudioLevel(rms)
                }
            }

            engine.prepare()
            try engine.start()
            isListening = true
            statusText = "Listening..."
        } catch {
            statusText = "Could not start microphone."
            isListening = false
            isVoiceDetected = false
        }
    }

    private func handleAudioLevel(_ rms: Float) {
        level = min(max(rms * 18, 0), 1)
        let detected = rms > 0.018

        if detected {
            isVoiceDetected = true
            statusText = "Voice detected."
            silenceTask?.cancel()
            silenceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                await MainActor.run {
                    self?.isVoiceDetected = false
                    if self?.isListening == true {
                        self?.statusText = "Listening..."
                    }
                }
            }
        }
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
