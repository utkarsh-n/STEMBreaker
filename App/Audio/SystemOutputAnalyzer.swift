import AVFoundation
import CoreMedia
import Foundation
import Observation
#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif

/// A user-authorized iOS 27 ScreenCaptureKit audio stream. This does not decode
/// protected library assets, record/export captured content, or change routes.
@MainActor
@Observable
final class SystemOutputAnalyzer {
    var isSupported: Bool {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) { return SCContentSharingPicker.shared.isAvailable }
        #endif
        return false
    }
    private(set) var isStarting = false
    private(set) var isListening = false
    private(set) var spectrum = [Float](repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
    private(set) var level: Float = 0
    private(set) var bandDecibels = [Float](repeating: AudioSpectrumAnalyzer.decibelFloor, count: AudioSpectrumAnalyzer.bandCount)
    private(set) var peakFrequency: Double?
    private(set) var rmsDecibels: Double?
    private(set) var energyDistribution: [Float] = [0, 0, 0]
    private(set) var analyzedSampleRate = 48_000.0
    private(set) var status = "Share audio through the system picker to visualize live output."
    var errorMessage: String?

    // The unavailable backend type never escapes this iOS-26-compatible wrapper.
    @ObservationIgnored private var backend: AnyObject?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let leftAnalyzer = AudioSpectrumAnalyzer()
    @ObservationIgnored private var leftSamples = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
    @ObservationIgnored private var rightSamples = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
    @ObservationIgnored private var lastAudibleTime = 0.0
    @ObservationIgnored private var beganListeningTime = 0.0

    isolated deinit {
        ticker?.cancel()
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) { (backend as? SystemOutputCaptureBackend)?.stop() }
        #endif
    }

    /// Presents Apple's consent UI. Only a filter returned by that picker can
    /// start this capture; microphone and camera controls remain disabled.
    func start() {
        guard !isStarting, !isListening else { return }
        #if canImport(ScreenCaptureKit)
        guard #available(iOS 27.0, *), SCContentSharingPicker.shared.isAvailable else {
            errorMessage = "Live output sharing requires iOS 27 and an available system sharing picker. Use playback position or the imported remix deck on this device."
            status = "Live output sharing is unavailable."
            return
        }
        generation += 1
        errorMessage = nil
        clearAnalysis()
        isStarting = true
        status = "Choose what to share in the system picker."
        let capture = SystemOutputCaptureBackend(owner: self, generation: generation)
        backend = capture
        capture.presentPicker()
        #else
        errorMessage = "Live output sharing is unavailable in this runtime. Try it on an iPhone with iOS 27; playback position and the imported remix deck remain available here."
        status = "Live output sharing is unavailable in this runtime."
        #endif
    }

    /// UI state clears immediately. Pending picker/start callbacks are invalid
    /// after this generation change, even when system cleanup finishes later.
    func stop() {
        generation += 1
        isStarting = false
        isListening = false
        ticker?.cancel()
        ticker = nil
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) { (backend as? SystemOutputCaptureBackend)?.stop() }
        #endif
        backend = nil
        clearAnalysis()
        status = "Live output sharing stopped."
    }

    fileprivate func isCurrent(_ request: Int) -> Bool {
        request == generation && (isStarting || isListening)
    }

    fileprivate func startingStream(_ request: Int) {
        guard isCurrent(request) else { return }
        isStarting = true
        isListening = false
        ticker?.cancel()
        ticker = nil
        clearAnalysis()
        status = "Starting the audio stream you shared."
    }

    fileprivate func started(_ request: Int) {
        guard isCurrent(request) else { return }
        isStarting = false
        isListening = true
        beganListeningTime = ProcessInfo.processInfo.systemUptime
        lastAudibleTime = beganListeningTime
        status = "Waiting for live audio samples."
        startTicker(request: request)
    }

    fileprivate func cancelled(_ request: Int) {
        guard isCurrent(request) else { return }
        stop()
        status = "Sharing was cancelled. Playback position and the remix deck remain available."
    }

    fileprivate func failed(_ request: Int, message: String) {
        guard isCurrent(request) else { return }
        stop()
        errorMessage = message
        status = "Live audio sharing ended. Use playback position or an imported file."
    }

    private func clearAnalysis() {
        spectrum = Array(repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
        level = 0
        bandDecibels = Array(repeating: AudioSpectrumAnalyzer.decibelFloor, count: AudioSpectrumAnalyzer.bandCount)
        peakFrequency = nil
        rmsDecibels = nil
        energyDistribution = [0, 0, 0]
        leftAnalyzer.reset()
    }

    private func startTicker(request: Int) {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
                guard let self, self.isCurrent(request), self.isListening else { break }
                #if canImport(ScreenCaptureKit)
                if #available(iOS 27.0, *), let capture = self.backend as? SystemOutputCaptureBackend {
                    self.updateAnalysis(from: capture.samples)
                }
                #endif
            }
        }
    }

    func updateAnalysis(from samples: SystemOutputSampleMailbox, at now: Double = ProcessInfo.processInfo.systemUptime) {
        let snapshot = samples.copyLatest(left: &leftSamples, right: &rightSamples)
        guard snapshot.hasSamples, now - snapshot.lastArrival < 0.35 else {
            clearAnalysis()
            if now - beganListeningTime > 1.5 {
                status = snapshot.decodingFailed
                    ? "The shared audio format could not be analyzed. Use playback position or an imported file."
                    : "No audio samples are arriving. Play sound in the shared content; some sources restrict capture."
            }
            return
        }
        let result = leftAnalyzer.analyzeStereo(leftSamples, rightSamples, sampleRate: snapshot.sampleRate)
        analyzedSampleRate = snapshot.sampleRate
        level = result.level
        if level > 0.000_1 {
            lastAudibleTime = now
            spectrum = result.spectrum
            bandDecibels = result.bandDecibels
            peakFrequency = result.peakFrequency
            rmsDecibels = result.rmsDecibels
            energyDistribution = result.energyDistribution
            status = "Live shared audio • analysis stays on your iPhone."
        } else {
            // A silent or restricted stream must not animate as if it contains
            // music. Silence alone cannot prove that a source is DRM-protected.
            clearAnalysis()
            if now - lastAudibleTime > 1.5 {
                status = "The shared stream is silent. It may be paused, quiet, or restricted; use playback position or an imported file."
            }
        }
    }
}

/// A fixed-size stereo ring. Sample conversion occurs on a dedicated serial
/// ScreenCaptureKit callback queue, outside AVAudioEngine's real-time thread.
final class SystemOutputSampleMailbox: @unchecked Sendable {
    struct Snapshot {
        var hasSamples: Bool
        var sampleRate: Double
        var lastArrival: Double
        var decodingFailed: Bool
    }

    private let lock = NSLock()
    private var leftRing = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
    private var rightRing = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
    private var writeIndex = 0
    private var filledCount = 0
    private var sampleRate = 48_000.0
    private var lastArrival = 0.0
    private var decodingFailed = false
    private var enabled = true
    private var sourceIdentifier: ObjectIdentifier?
    // Only accessed from the one serial sample-handler queue.
    private var conversionBuffer: AVAudioPCMBuffer?

    func disable() {
        lock.lock()
        enabled = false
        filledCount = 0
        lock.unlock()
    }

    func bind(to identifier: ObjectIdentifier) {
        lock.lock()
        sourceIdentifier = identifier
        filledCount = 0
        writeIndex = 0
        lastArrival = 0
        decodingFailed = false
        enabled = true
        lock.unlock()
    }

    @available(iOS 27.0, *)
    func push(_ sampleBuffer: CMSampleBuffer, arrivalTime: Double = ProcessInfo.processInfo.systemUptime, sourceIdentifier incomingSource: ObjectIdentifier? = nil) {
        guard sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = AVAudioFormat(formatDescription: description) else { markDecodeFailure(); return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, count <= 16_384, format.sampleRate > 0,
              format.channelCount > 0, format.channelCount <= 2 else { markDecodeFailure(); return }

        if conversionBuffer == nil || conversionBuffer!.format != format || conversionBuffer!.frameCapacity < AVAudioFrameCount(count) {
            conversionBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        }
        guard let buffer = conversionBuffer, let channels = buffer.floatChannelData else { markDecodeFailure(); return }
        buffer.frameLength = AVAudioFrameCount(count)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard result == noErr else { markDecodeFailure(); return }
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard enabled, incomingSource == nil || incomingSource == sourceIdentifier else { return }
        if sampleRate != format.sampleRate { filledCount = 0; writeIndex = 0 }

        let channelCount = Int(format.channelCount)
        let interleaved = format.isInterleaved
        let capacity = AudioSpectrumAnalyzer.sampleCount
        for frame in max(0, count - capacity)..<count {
            let left = channels[0][interleaved ? frame * channelCount : frame]
            let right = channelCount == 1 ? left : interleaved ? channels[0][frame * channelCount + 1] : channels[1][frame]
            leftRing[writeIndex] = left.isFinite ? left : 0
            rightRing[writeIndex] = right.isFinite ? right : 0
            writeIndex = (writeIndex + 1) % capacity
            filledCount = min(capacity, filledCount + 1)
        }
        sampleRate = format.sampleRate
        lastArrival = arrivalTime.isFinite ? arrivalTime : ProcessInfo.processInfo.systemUptime
        decodingFailed = false
    }

    func copyLatest(left: inout [Float], right: inout [Float]) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = Snapshot(hasSamples: filledCount > 0, sampleRate: sampleRate, lastArrival: lastArrival, decodingFailed: decodingFailed)
        let capacity = AudioSpectrumAnalyzer.sampleCount
        guard left.count == capacity, right.count == capacity else { return snapshot }
        let zeroCount = capacity - filledCount
        let start = (writeIndex - filledCount + capacity) % capacity
        for index in 0..<zeroCount { left[index] = 0; right[index] = 0 }
        for index in 0..<filledCount {
            let source = (start + index) % capacity
            left[zeroCount + index] = leftRing[source]
            right[zeroCount + index] = rightRing[source]
        }
        return snapshot
    }

    private func markDecodeFailure() {
        lock.lock()
        decodingFailed = true
        lock.unlock()
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
@MainActor
private final class SystemOutputCaptureBackend: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    weak var owner: SystemOutputAnalyzer?
    let generation: Int
    nonisolated let samples = SystemOutputSampleMailbox()
    private var stream: SCStream?
    private var stopped = false
    private var hasPickerObserver = false
    private let sampleQueue = DispatchQueue(label: "com.utkarsh.stembreaker.shared-audio", qos: .userInitiated)

    init(owner: SystemOutputAnalyzer, generation: Int) {
        self.owner = owner
        self.generation = generation
        super.init()
    }

    func presentPicker() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        hasPickerObserver = true
        picker.isActive = true
        picker.present()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        samples.disable()
        let picker = SCContentSharingPicker.shared
        if hasPickerObserver { picker.remove(self); hasPickerObserver = false }
        picker.isActive = false
        let active = stream
        stream = nil
        if let active { Task { try? await active.stopCapture() } }
    }

    private func startStream(filter: SCContentFilter) async {
        guard !stopped, owner?.isCurrent(generation) == true, stream == nil else { return }
        owner?.startingStream(generation)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Do not request microphone/camera or receive/store screen frames.
        // Low video dimensions minimize any internal screen work.
        configuration.width = 32
        configuration.height = 32
        let candidate = SCStream(filter: filter, configuration: configuration, delegate: self)
        stream = candidate
        samples.bind(to: ObjectIdentifier(candidate))
        do {
            try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await candidate.startCapture()
            guard !stopped, stream === candidate, owner?.isCurrent(generation) == true else {
                try? await candidate.stopCapture()
                return
            }
            owner?.started(generation)
        } catch {
            guard !stopped, stream === candidate else { return }
            owner?.failed(generation, message: "The system could not share this audio. \(error.localizedDescription)")
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            // Cancelling an edit of an existing sharing session keeps the
            // current stream. Only the initial pending request is cancelled.
            if stream == nil, self.owner?.isStarting == true {
                self.owner?.cancelled(self.generation)
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.applySelection(filter: filter, associatedStream: stream) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.owner?.failed(self.generation, message: "The system sharing picker could not open. \(message)")
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        samples.push(sampleBuffer, sourceIdentifier: ObjectIdentifier(stream))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, !self.stopped, self.stream === stream else { return }
            self.owner?.failed(self.generation, message: "System audio sharing stopped. \(message)")
        }
    }

    private func applySelection(filter: SCContentFilter, associatedStream: SCStream?) async {
        guard !stopped, owner?.isCurrent(generation) == true else { return }
        if let current = stream {
            if let associatedStream, associatedStream !== current { return }
            // updateContentFilter is explicitly unavailable on iOS 27. Create
            // a replacement stream from the new user-authorized picker filter.
            owner?.startingStream(generation)
            stream = nil
            samples.disable()
            try? await current.stopCapture()
            guard !stopped, owner?.isCurrent(generation) == true else { return }
        }
        await startStream(filter: filter)
    }
}
#endif
