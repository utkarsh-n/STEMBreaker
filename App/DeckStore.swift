import Foundation
import Observation
import StemCore

enum AudioSource: String, CaseIterable, Identifiable {
    case deck = "Remix deck"
    case appleMusic = "Apple Music"
    var id: String { rawValue }
}

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case spectrum = "Spectrum", history = "History", orbit = "Orbit"
    var id: String { rawValue }
}

enum DeckSheet: String, Identifiable {
    case library, guide, importOptions
    var id: String { rawValue }
}

@MainActor @Observable
final class DeckStore {
    let engine = RemixEngine()
    let music = AppleMusicBridge()
    let microphone = MicrophoneAnalyzer()
    let outputAudio = SystemOutputAnalyzer()
    var source: AudioSource = .deck
    var visualizer: VisualizerStyle = .spectrum
    private(set) var spectrumHistory: [[Float]] = []
    static let historyInterval = 0.05
    static let historyCapacity = 160
    var sheet: DeckSheet?
    var busy = false
    var progress = 0.0
    var progressLabel = "Preparing instrument"
    var message: String?
    var exportURL: URL?
    var isExporting = false
    private(set) var isSeparating = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var visualizationTask: Task<Void, Never>?
    @ObservationIgnored private var historyIdentity = ""
    @ObservationIgnored private var visualizationActive = true
    private var prepared = false

    var isPlaying: Bool { source == .deck ? engine.isPlaying : music.isPlaying }
    var position: Double { source == .deck ? engine.position : music.playbackTime }
    var duration: Double { source == .deck ? engine.duration : music.duration }
    var title: String {
        source == .deck ? engine.session?.title ?? "Loading session" : music.currentItem?.title ?? "Choose a song"
    }
    var subtitle: String {
        source == .deck ? "ORIGINAL DEMO / FOUR STEMS" : music.currentItem?.artist ?? "Connect your music library"
    }
    var spectrum: [Float] {
        if source == .deck { return engine.spectrum }
        if outputAudio.isListening { return outputAudio.spectrum }
        return microphone.isListening ? microphone.spectrum : Array(repeating: 0, count: 48)
    }
    var bandDecibels: [Float] {
        if source == .deck { return engine.bandDecibels }
        if outputAudio.isListening { return outputAudio.bandDecibels }
        return microphone.isListening ? microphone.bandDecibels : Array(repeating: -120, count: 48)
    }
    var peakFrequency: Double? {
        if source == .deck { return engine.peakFrequency }
        if outputAudio.isListening { return outputAudio.peakFrequency }
        return microphone.isListening ? microphone.peakFrequency : nil
    }
    var rmsDecibels: Double? {
        if source == .deck { return engine.rmsDecibels }
        if outputAudio.isListening { return outputAudio.rmsDecibels }
        return microphone.isListening ? microphone.rmsDecibels : nil
    }
    var energyDistribution: [Float] {
        if source == .deck { return engine.energyDistribution }
        if outputAudio.isListening { return outputAudio.energyDistribution }
        return microphone.isListening ? microphone.energyDistribution : [0, 0, 0]
    }
    var analysisSampleRate: Double {
        if source == .deck { return engine.session?.sampleRate ?? 44_100 }
        if outputAudio.isListening { return outputAudio.analyzedSampleRate }
        return microphone.isListening ? microphone.analyzedSampleRate : 48_000
    }
    var frequencyCenters: [Double] { AudioSpectrumAnalyzer.bandCenters(sampleRate: analysisSampleRate) }
    var maximumFrequency: Double { min(20_000, analysisSampleRate / 2) }
    var meterLabel: String {
        if source == .deck { return engine.isPlaying ? "LIVE MIX" : "MIX AT PLAYHEAD" }
        if outputAudio.isListening { return "LIVE OUTPUT" }
        return microphone.isListening ? "MICROPHONE INPUT" : "POSITION ONLY"
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        await loadDemo()
        music.startObserving()
        setVisualizationActive(visualizationActive)
    }

    isolated deinit { visualizationTask?.cancel(); importTask?.cancel() }

    /// History runs only while the instrument is visible. Each column is a
    /// measured spectrum; pauses freeze the display rather than adding fiction.
    func setVisualizationActive(_ active: Bool) {
        visualizationActive = active
        visualizationTask?.cancel()
        visualizationTask = nil
        guard active else { return }
        clearVisualizationHistory()
        visualizationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { break }
                let identity = self.source == .deck
                    ? "deck:\(self.engine.session?.title ?? ""):\(self.analysisSampleRate)"
                    : "music:\(self.music.currentItem?.persistentID ?? 0):\(self.outputAudio.isListening):\(self.microphone.isListening):\(self.analysisSampleRate)"
                if identity != self.historyIdentity {
                    self.spectrumHistory.removeAll(keepingCapacity: true)
                    self.historyIdentity = identity
                }
                guard self.source == .deck ? self.engine.isPlaying : (self.outputAudio.isListening || self.microphone.isListening) else { continue }
                self.spectrumHistory.append(self.bandDecibels)
                if self.spectrumHistory.count > Self.historyCapacity { self.spectrumHistory.removeFirst() }
            }
        }
    }

    func clearVisualizationHistory() {
        spectrumHistory.removeAll(keepingCapacity: true)
        historyIdentity = ""
    }

    func loadDemo() async {
        guard !busy else { return }
        busy = true
        progress = 0
        progressLabel = "Opening the instrument"
        engine.pause()
        microphone.stop()
        outputAudio.stop()
        defer { busy = false }
        do {
            let session = try await DemoLoader.load()
            microphone.stop()
            outputAudio.stop()
            music.pausePlayback()
            try engine.load(session)
            source = .deck
            clearVisualizationHistory()
            exportURL = nil
        } catch { message = error.localizedDescription }
    }

    func changeSource(_ newSource: AudioSource) {
        guard newSource != source else { return }
        if newSource == .appleMusic { engine.pause(); music.refresh() }
        else { microphone.stop(); outputAudio.stop(); music.pausePlayback() }
        source = newSource
        clearVisualizationHistory()
    }

    func togglePlayback() {
        if source == .appleMusic { music.togglePlayback() }
        else {
            do { if engine.isPlaying { engine.pause() } else { music.pausePlayback(); try engine.play() } }
            catch { message = error.localizedDescription }
        }
    }

    func seek(_ time: Double) {
        if source == .deck { engine.seek(to: time) } else { music.seek(to: time) }
        clearVisualizationHistory()
    }

    func toggleMicrophone() async {
        if microphone.isListening { microphone.stop() }
        else { engine.pause(); outputAudio.stop(); await microphone.start() }
        clearVisualizationHistory()
    }

    func toggleOutputAudio() async {
        if outputAudio.isListening || outputAudio.isStarting { outputAudio.stop() }
        else { engine.pause(); microphone.stop(); outputAudio.start() }
        clearVisualizationHistory()
    }

    func startImport(_ urls: [URL], fourStems: Bool) {
        guard !busy else { return }
        importTask = Task { [weak self] in
            await self?.importFiles(urls, fourStems: fourStems)
            self?.importTask = nil
        }
    }

    func cancelImport() { importTask?.cancel() }

    private func importFiles(_ urls: [URL], fourStems: Bool) async {
        guard !busy, !urls.isEmpty else { return }
        busy = true
        isSeparating = true
        progress = 0
        progressLabel = fourStems ? "Reading four stems" : "Reading audio"
        engine.pause()
        microphone.stop()
        outputAudio.stop()
        defer { busy = false; isSeparating = false }
        do {
            let session: StemSession
            if fourStems { session = try await AudioImporter.importStems(urls: urls) }
            else {
                session = try await AudioImporter.separate(url: urls[0]) { [weak self] value, label in
                    Task { @MainActor [weak self] in self?.progress = value; self?.progressLabel = label }
                }
            }
            try Task.checkCancellation()
            engine.pause()
            microphone.stop()
            music.pausePlayback()
            try engine.load(session)
            source = .deck
            clearVisualizationHistory()
            exportURL = nil
        } catch { if !(error is CancellationError) { message = error.localizedDescription } }
    }

    func export() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do { exportURL = try await engine.exportMix() }
        catch { message = error.localizedDescription }
    }
}
