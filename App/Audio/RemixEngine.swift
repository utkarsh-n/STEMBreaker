import AVFoundation
import Foundation
import Observation
import StemCore

enum StemAudioError: LocalizedError {
    case invalidSession
    case clipTooLong
    case unavailableFormat
    case noSession

    var errorDescription: String? {
        switch self {
        case .invalidSession: "The four channels must contain matching stereo audio."
        case .clipTooLong: "Use a clip up to three minutes long, or a shorter clip at high sample rates."
        case .unavailableFormat: "This audio format could not be opened."
        case .noSession: "Load a demo or an audio file first."
        }
    }
}

@MainActor
@Observable
final class RemixEngine {
    private(set) var session: StemSession?
    private(set) var isPlaying = false
    private(set) var position = 0.0
    var duration: Double { session?.duration ?? 0 }
    private(set) var levels = [Float](repeating: 0, count: 4)
    private(set) var spectrum = [Float](repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
    private(set) var bandDecibels = [Float](repeating: AudioSpectrumAnalyzer.decibelFloor, count: AudioSpectrumAnalyzer.bandCount)
    private(set) var peakFrequency: Double?
    private(set) var rmsDecibels: Double?
    private(set) var energyDistribution: [Float] = [0, 0, 0]
    private(set) var gains = [Float](repeating: 1, count: 4)
    private(set) var muted = Set<Int>()
    private(set) var soloed = Set<Int>()
    var loopEnabled = true {
        didSet {
            guard oldValue != loopEnabled, isPlaying else { return }
            // Read the playhead using the previous looping mode. After multiple
            // passes, turning looping off must retain the current wrapped frame.
            let current = currentPosition(looping: oldValue)
            pause()
            position = current
            do { try play() } catch { errorMessage = error.localizedDescription }
        }
    }
    var errorMessage: String?

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var players = (0..<4).map { _ in AVAudioPlayerNode() }
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var startFrame = 0
    @ObservationIgnored private var scheduledFrames = 0
    @ObservationIgnored private var startHostTime: UInt64 = 0
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private let analyzer = AudioSpectrumAnalyzer()
    @ObservationIgnored private var mixedWindow = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
    @ObservationIgnored private var mixedRightWindow = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)

    private let chunkFrames = 8_192
    private let queuedChunks = 4

    init() {
        registerNotifications()
    }

    deinit {
        ticker?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func load(_ session: StemSession) throws {
        guard session.channels.count == 4,
              session.sampleRate.isFinite, (8_000...96_000).contains(session.sampleRate),
              let first = session.channels.first, !first.left.isEmpty,
              session.channels.allSatisfy({ $0.left.count == first.left.count && $0.right.count == first.left.count }) else {
            throw StemAudioError.invalidSession
        }
        // Chunked playback does not duplicate a whole session into four giant
        // AVAudioPCMBuffers. The retained source still needs a firm size limit.
        guard session.duration <= 180, first.left.count <= 48_000 * 180 else {
            throw StemAudioError.clipTooLong
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 2) else {
            throw StemAudioError.unavailableFormat
        }

        pause()
        engine.stop()
        for player in players {
            if player.engine != nil { engine.detach(player) }
        }
        self.session = session
        self.format = format
        position = 0
        resetMix()
        configureGraph()
        updateVisualization()
        errorMessage = nil
    }

    func play() throws {
        guard session != nil, format != nil else { throw StemAudioError.noSession }
        guard !isPlaying else { return }
        if position >= duration { position = 0 }

        let audioSession = AVAudioSession.sharedInstance()
        // The top-level app pauses MusicKit before remix playback. Mixing keeps
        // a separate Listen mode from needlessly interrupting system music.
        try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audioSession.setActive(true)

        for player in players { player.stop() }
        startFrame = Int(position * (session?.sampleRate ?? 1))
        scheduledFrames = 0
        replenishBuffers(elapsedFrames: 0)
        applyVolumes()
        engine.prepare()
        try engine.start()
        // Every player has its own sample-time-zero timeline, all anchored to
        // exactly the same future host time for sample-aligned stem playback.
        startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.045)
        let commonTime = AVAudioTime(hostTime: startHostTime)
        for player in players { player.play(at: commonTime) }
        isPlaying = true
        errorMessage = nil
        startTicker()
    }

    func pause() {
        // A user/source switch can pause while an interruption is active.
        // Revoke any queued auto-resume so an old deck cannot restart later.
        wasPlayingBeforeInterruption = false
        if isPlaying, engine.isRunning { position = currentPosition() }
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        for player in players { player.stop() }
        engine.pause()
        levels = Array(repeating: 0, count: 4)
        spectrum = Array(repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
        bandDecibels = Array(repeating: AudioSpectrumAnalyzer.decibelFloor, count: AudioSpectrumAnalyzer.bandCount)
        peakFrequency = nil
        rmsDecibels = nil
        energyDistribution = [0, 0, 0]
        analyzer.reset()
    }

    func seek(to time: Double) {
        let shouldResume = isPlaying
        pause()
        position = min(duration, max(0, time.isFinite ? time : 0))
        updateVisualization()
        if shouldResume {
            do { try play() } catch { errorMessage = error.localizedDescription }
        }
    }

    func setGain(_ gain: Float, channel: Int) {
        guard gains.indices.contains(channel) else { return }
        gains[channel] = min(1, max(0, gain.isFinite ? gain : 0))
        applyVolumes()
        if !isPlaying { updateVisualization() }
    }

    func toggleMute(_ index: Int) {
        guard gains.indices.contains(index) else { return }
        if muted.contains(index) { muted.remove(index) } else { muted.insert(index) }
        applyVolumes()
        if !isPlaying { updateVisualization() }
    }

    func toggleSolo(_ index: Int) {
        guard gains.indices.contains(index) else { return }
        if soloed.contains(index) { soloed.remove(index) } else { soloed.insert(index) }
        applyVolumes()
        if !isPlaying { updateVisualization() }
    }

    func resetMix() {
        gains = Array(repeating: 1, count: 4)
        muted.removeAll()
        soloed.removeAll()
        applyVolumes()
        if !isPlaying { updateVisualization() }
    }

    func exportMix() async throws -> URL {
        guard let session else { throw StemAudioError.noSession }
        let volumes = effectiveGains()
        // Capture value types before leaving the main actor; edits during an
        // export cannot produce a mix with half-old and half-new fader values.
        let task = Task.detached(priority: .userInitiated) {
            try Self.writeMix(session: session, volumes: volumes)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func configureGraph() {
        guard let format else { return }
        for player in players {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = 1
        applyVolumes()
    }

    private func effectiveGains() -> [Float] {
        gains.indices.map { index in
            muted.contains(index) || (!soloed.isEmpty && !soloed.contains(index)) ? 0 : gains[index]
        }
    }

    private func applyVolumes() {
        let volumes = effectiveGains()
        for index in players.indices { players[index].volume = volumes[index] }
    }

    private func elapsedFrames() -> Int {
        guard let session else { return 0 }
        guard let renderTime = players.first?.lastRenderTime,
              let playerTime = players.first?.playerTime(forNodeTime: renderTime), playerTime.sampleTime >= 0,
              playerTime.sampleRate > 0 else {
            // A node has no render timestamp before the shared start time.
            return 0
        }
        return max(0, Int(Double(playerTime.sampleTime) * session.sampleRate / playerTime.sampleRate))
    }

    private func currentPosition(looping: Bool? = nil) -> Double {
        guard let session, let first = session.channels.first else { return position }
        let absoluteFrame = startFrame + elapsedFrames()
        if looping ?? loopEnabled { return Double(absoluteFrame % first.left.count) / session.sampleRate }
        return min(duration, Double(absoluteFrame) / session.sampleRate)
    }

    /// All four nodes receive the same sample-time positions. Buffer allocation
    /// and sample copies happen here on the main actor, ahead of playback.
    private func replenishBuffers(elapsedFrames: Int) {
        guard let session, let format, let first = session.channels.first else { return }
        let totalFrames = first.left.count
        while scheduledFrames - elapsedFrames < chunkFrames * queuedChunks {
            let absoluteStart = startFrame + scheduledFrames
            if !loopEnabled && absoluteStart >= totalFrames { break }
            let count = loopEnabled ? chunkFrames : min(chunkFrames, totalFrames - absoluteStart)
            guard count > 0 else { break }
            let scheduledTime = AVAudioTime(sampleTime: AVAudioFramePosition(scheduledFrames), atRate: session.sampleRate)
            var buffers: [AVAudioPCMBuffer] = []
            for index in 0..<4 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let data = buffer.floatChannelData else { return }
                buffer.frameLength = AVAudioFrameCount(count)
                let source = session.channels[index]
                for frame in 0..<count {
                    let sourceFrame = (absoluteStart + frame) % totalFrames
                    let left = source.left[sourceFrame]
                    let right = source.right[sourceFrame]
                    data[0][frame] = left.isFinite ? left : 0
                    data[1][frame] = right.isFinite ? right : 0
                }
                buffers.append(buffer)
            }
            for index in players.indices {
                players[index].scheduleBuffer(buffers[index], at: scheduledTime, options: [], completionHandler: nil)
            }
            scheduledFrames += count
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
                guard let self, self.isPlaying else { break }
                self.tick()
            }
        }
    }

    private func tick() {
        let elapsed = elapsedFrames()
        position = currentPosition()
        if !loopEnabled && position >= duration {
            pause()
            position = duration
            return
        }
        replenishBuffers(elapsedFrames: elapsed)
        updateVisualization()
    }

    private func updateVisualization() {
        guard let session, let first = session.channels.first, !first.left.isEmpty else { return }
        let frameCount = first.left.count
        let currentFrame = min(frameCount - 1, max(0, Int(position * session.sampleRate)))
        // During playback analyze the window ending at the actual player
        // position, matching the live-input analyzers. A paused deck shows a
        // preview from its selected position instead of inventing live motion.
        let windowStart = isPlaying ? startFrame + elapsedFrames() - mixedWindow.count : currentFrame
        let volumes = effectiveGains()
        var channelSquares = [Float](repeating: 0, count: 4)
        for frame in mixedWindow.indices {
            let unwrapped = windowStart + frame
            let sourceFrame = ((unwrapped % frameCount) + frameCount) % frameCount
            let hasPlayed = !isPlaying || unwrapped >= startFrame
            let hasSample = hasPlayed && unwrapped >= 0 && (loopEnabled || unwrapped < frameCount)
            var leftMix: Float = 0
            var rightMix: Float = 0
            for channel in 0..<4 {
                let source = session.channels[channel]
                let rawLeft = hasSample ? source.left[sourceFrame] : 0
                let rawRight = hasSample ? source.right[sourceFrame] : 0
                let left = (rawLeft.isFinite ? rawLeft : 0) * volumes[channel]
                let right = (rawRight.isFinite ? rawRight : 0) * volumes[channel]
                channelSquares[channel] += (left * left + right * right) * 0.5
                leftMix += left
                rightMix += right
            }
            mixedWindow[frame] = min(1, max(-1, leftMix))
            mixedRightWindow[frame] = min(1, max(-1, rightMix))
        }
        levels = channelSquares.map { min(1, sqrt($0 / Float(mixedWindow.count)) * 2) }
        let result = analyzer.analyzeStereo(mixedWindow, mixedRightWindow, sampleRate: session.sampleRate)
        spectrum = result.spectrum
        bandDecibels = result.bandDecibels
        peakFrequency = result.peakFrequency
        rmsDecibels = result.rmsDecibels
        energyDistribution = result.energyDistribution
    }

    private func registerNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in self?.handleInterruption(type: rawType, options: rawOptions) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
                self.pause()
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            let changedEngine = notification.object as? AVAudioEngine
            Task { @MainActor [weak self] in
                guard let self, changedEngine === self.engine, self.isPlaying, !self.engine.isRunning else { return }
                // Keep the last published position if a route change invalidated
                // player timestamps before this notification arrived.
                let lastPosition = self.position
                self.pause()
                self.position = lastPosition
                self.errorMessage = "The audio route changed. Tap play to continue."
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pause()
                self.engine = AVAudioEngine()
                self.players = (0..<4).map { _ in AVAudioPlayerNode() }
                self.configureGraph()
                self.errorMessage = "Audio restarted. Tap play to continue."
            }
        })
    }

    private func handleInterruption(type: UInt, options: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch type {
        case .began:
            let wasPlaying = isPlaying
            pause()
            wasPlayingBeforeInterruption = wasPlaying
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            if wasPlayingBeforeInterruption && shouldResume {
                do { try play() } catch { errorMessage = error.localizedDescription }
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            pause()
        }
    }

    nonisolated private static func writeMix(session: StemSession, volumes: [Float]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("STEMBreaker Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = session.title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(8).joined(separator: "-")
        let url = folder.appendingPathComponent("\(name.isEmpty ? "STEM-Breaker" : name)-\(UUID().uuidString.prefix(8)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: session.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192),
              let data = buffer.floatChannelData else { throw StemAudioError.unavailableFormat }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let totalFrames = session.channels[0].left.count
            var offset = 0
            while offset < totalFrames {
                try Task.checkCancellation()
                let count = min(8_192, totalFrames - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                for frame in 0..<count {
                    var left: Float = 0
                    var right: Float = 0
                    for channel in 0..<4 {
                        let stem = session.channels[channel]
                        let l = stem.left[offset + frame]
                        let r = stem.right[offset + frame]
                        left += (l.isFinite ? l : 0) * volumes[channel]
                        right += (r.isFinite ? r : 0) * volumes[channel]
                    }
                    data[0][frame] = min(1, max(-1, left))
                    data[1][frame] = min(1, max(-1, right))
                }
                try file.write(from: buffer)
                offset += count
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
