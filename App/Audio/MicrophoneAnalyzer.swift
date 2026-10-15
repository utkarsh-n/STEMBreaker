import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MicrophoneAnalyzer {
    private(set) var isListening = false
    private(set) var spectrum = [Float](repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
    private(set) var level: Float = 0
    private(set) var bandDecibels = [Float](repeating: AudioSpectrumAnalyzer.decibelFloor, count: AudioSpectrumAnalyzer.bandCount)
    private(set) var peakFrequency: Double?
    private(set) var rmsDecibels: Double?
    private(set) var energyDistribution: [Float] = [0, 0, 0]
    private(set) var analyzedSampleRate = 44_100.0
    private(set) var routeDescription = "Microphone input analyzes sound around your iPhone."
    var errorMessage: String?

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private let mailbox = MicrophoneSampleMailbox()
    @ObservationIgnored private let analyzer = AudioSpectrumAnalyzer()
    @ObservationIgnored private var samples = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
    @ObservationIgnored private var sampleRate = 44_100.0
    @ObservationIgnored private var hasTap = false
    @ObservationIgnored private var ownsRecordingSession = false
    @ObservationIgnored private var previousPreferredInput: AVAudioSessionPortDescription?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        registerNotifications()
    }

    deinit {
        ticker?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// This is room/input sound only. An AVAudioEngine microphone tap never
    /// contains another app's digital playback or its headphone output.
    func start() async {
        guard !isListening else { return }
        generation += 1
        let requestGeneration = generation
        let granted = await AVAudioApplication.requestRecordPermission()
        guard requestGeneration == generation else { return }
        guard granted else {
            errorMessage = "Enable microphone access in Settings to visualize sound around your iPhone."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            let existingOutputs = session.currentRoute.outputs
            var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP]
            // Preserve an existing speaker route without overriding a selected
            // Bluetooth, wired, USB, or AirPlay output. HFP is deliberately not
            // enabled: its paired input/output route takes priority over A2DP.
            if !existingOutputs.isEmpty, existingOutputs.allSatisfy({ $0.portType == .builtInSpeaker }) {
                options.insert(.defaultToSpeaker)
            }
            previousPreferredInput = session.preferredInput
            // Measurement mode can lower playback volume through its output
            // processing policy. Default mode leaves normal music playback in
            // place while the built-in microphone supplies room sound.
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            ownsRecordingSession = true
            try session.setActive(true)
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtInMic)
            }
            updateRouteDescription()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw StemAudioError.unavailableFormat }
            sampleRate = format.sampleRate
            mailbox.reset()
            if hasTap { input.removeTap(onBus: 0) }
            // Keep the input graph running without feeding mic sound back to
            // the speaker. The tap observes actual microphone input.
            engine.connect(input, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            let mailbox = self.mailbox
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                mailbox.push(buffer)
            }
            hasTap = true
            engine.prepare()
            try engine.start()
            isListening = true
            errorMessage = nil
            startTicker()
        } catch {
            stop()
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        generation += 1
        ticker?.cancel()
        ticker = nil
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        isListening = false
        mailbox.reset()
        clearAnalysis()
        // Preserve a mixing playback session for MusicKit. Avoid deactivating
        // the app's shared session while the user's library song is playing.
        if ownsRecordingSession {
            let session = AVAudioSession.sharedInstance()
            let restoredInput = previousPreferredInput.flatMap { previous in
                session.availableInputs?.first(where: { $0.uid == previous.uid })
            }
            try? session.setPreferredInput(restoredInput)
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            ownsRecordingSession = false
            previousPreferredInput = nil
        }
    }

    private func startTicker() {
        ticker?.cancel()
        let requestGeneration = generation
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
                guard !Task.isCancelled, let self, self.isListening,
                      self.generation == requestGeneration else { break }
                var observedSampleRate = self.sampleRate
                guard self.mailbox.copyLatest(into: &self.samples, sampleRate: &observedSampleRate) else {
                    self.clearAnalysis()
                    continue
                }
                self.sampleRate = observedSampleRate
                let result = self.analyzer.analyze(self.samples, sampleRate: observedSampleRate)
                self.analyzedSampleRate = observedSampleRate
                self.spectrum = result.spectrum
                self.level = result.level
                self.bandDecibels = result.bandDecibels
                self.peakFrequency = result.peakFrequency
                self.rmsDecibels = result.rmsDecibels
                self.energyDistribution = result.energyDistribution
            }
        }
    }

    private func clearAnalysis() {
        spectrum = Array(repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
        level = 0
        bandDecibels = Array(repeating: AudioSpectrumAnalyzer.decibelFloor, count: AudioSpectrumAnalyzer.bandCount)
        peakFrequency = nil
        rmsDecibels = nil
        energyDistribution = [0, 0, 0]
        analyzer.reset()
    }

    private func registerNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, self.isListening, AVAudioSession.InterruptionType(rawValue: type) == .began else { return }
                self.stop()
                self.errorMessage = "Listening was interrupted. Tap Listen to start again."
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                self.updateRouteDescription()
                if AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable {
                    self.stop()
                    self.errorMessage = "The input route changed. Tap Listen to start again."
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            let changedEngine = notification.object as? AVAudioEngine
            Task { @MainActor [weak self] in
                guard let self, changedEngine === self.engine, self.isListening, !self.engine.isRunning else { return }
                self.stop()
                self.errorMessage = "The input route changed. Tap Listen to start again."
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stop()
                self.engine = AVAudioEngine()
            }
        })
    }

    private func updateRouteDescription() {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first
        let inputName = input?.portType == .builtInMic ? "iPhone microphone" : input?.portName ?? "Microphone"
        let externalOutput = session.currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones].contains($0.portType)
        }
        routeDescription = externalOutput
            ? "\(inputName) • Bluetooth/headphone playback is not captured; only sound reaching the microphone is analyzed."
            : "\(inputName) • Only sound reaching the microphone is analyzed."
    }
}
