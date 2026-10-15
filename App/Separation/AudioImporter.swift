import Accelerate
import AVFoundation
import CoreML
import Foundation
import StemCore

public enum AudioImporter {
    public static let maximumDuration = 180.0
    public static let sampleRate = 44_100.0

    public static func separate(url: URL, progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemSession {
        let worker = Task.detached(priority: .userInitiated) {
            progress(0.01, "Reading local audio")
            let source = try decode(url)
            try Task.checkCancellation()
            progress(0.06, "Loading the on-device AI model")
            guard let modelURL = Bundle.main.url(forResource: "Spleeter2Model", withExtension: "mlmodelc") else { throw SeparationError.modelMissing }
            let separator = try SpleeterSeparator(modelURL: modelURL)
            let channels = try separator.separate(source, progress: progress)
            progress(0.96, "Checking separated tracks")
            let result = try StemSession(
                title: url.deletingPathExtension().lastPathComponent,
                sampleRate: sampleRate,
                channels: channels,
                provenance: "On-device Spleeter AI: vocals + accompaniment. Drums, bass, and other are DSP estimates from accompaniment; they can contain bleed. No audio was uploaded."
            ).validated()
            progress(1, "Ready to remix")
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    public static func importStems(urls: [URL]) async throws -> StemSession {
        let worker = Task.detached(priority: .userInitiated) {
            guard urls.count == 4 else { throw SeparationError.fourFilesRequired }
            let ordered = try orderStemFiles(urls)
            var tracks = [StereoSamples]()
            for url in ordered {
                try Task.checkCancellation()
                tracks.append(try decode(url))
            }
            guard let count = tracks.map(\.count).min(),
                  tracks.allSatisfy({ abs($0.count - count) <= Int(sampleRate * 0.02) }) else { throw SeparationError.stemDurationsDiffer }
            // Tiny encoder-padding differences are trimmed; longer mismatches are rejected.
            tracks = tracks.map { StereoSamples(left: Array($0.left.prefix(count)), right: Array($0.right.prefix(count))) }
            return try StemSession(title: "Imported stems", sampleRate: sampleRate, channels: tracks,
                                   provenance: "Four supplied stem files • Original audio tracks, assigned by filename. No AI or instrument estimation applied.").validated()
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func orderStemFiles(_ urls: [URL]) throws -> [URL] {
        let aliases: [[String]] = [["vocals", "vocal", "vox"], ["drums", "drum"], ["bass"], ["other", "music", "instrumental", "instruments"]]
        var result = [Int: URL]()
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let roles = aliases.indices.filter { role in aliases[role].contains { alias in words.contains(alias) } }
            guard roles.count == 1, let role = roles.first, result[role] == nil else { throw SeparationError.stemNames }
            result[role] = url
        }
        guard result.count == 4 else { throw SeparationError.stemNames }
        return (0..<4).map { result[$0]! }
    }

    /// AVAudioFile decodes supported unprotected files. Conversion is streamed in small buffers
    /// so a 192 kHz input never requires a whole source-rate allocation.
    static func decode(_ url: URL) throws -> StereoSamples {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw SeparationError.unsupportedAudio }
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0, format.sampleRate >= 8_000, format.sampleRate <= 192_000,
              format.channelCount >= 1, format.channelCount <= 2 else { throw SeparationError.unsupportedAudio }
        guard duration <= maximumDuration else { throw SeparationError.tooLong }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else { throw SeparationError.unsupportedAudio }
        var left = [Float]()
        var right = [Float]()
        left.reserveCapacity(Int(duration * sampleRate) + 1_024)
        right.reserveCapacity(Int(duration * sampleRate) + 1_024)
        var inputError: Error?
        var reachedEnd = false
        repeat {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                if reachedEnd || file.framePosition >= file.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(requested), file.length - file.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                    inputError = SeparationError.unsupportedAudio
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer, frameCount: framesToRead)
                    if buffer.frameLength == 0 {
                        reachedEnd = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return buffer
                } catch {
                    inputError = error
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let inputError { throw inputError }
            if let conversionError { throw conversionError }
            guard status != .error, let data = output.floatChannelData else { throw SeparationError.unsupportedAudio }
            let frames = Int(output.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: frames))
            guard left.count <= Int(maximumDuration * sampleRate) + 2_048 else { throw SeparationError.tooLong }
            if status == .endOfStream { break }
            if frames == 0, reachedEnd { break }
        } while true
        guard !left.isEmpty else { throw SeparationError.emptyAudio }
        guard left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite) else { throw StemError.nonFiniteAudio }
        return StereoSamples(left: left, right: right)
    }
}

public enum SeparationError: Error, LocalizedError, Sendable {
    case unsupportedAudio, tooLong, emptyAudio, modelMissing, modelOutput
    case fourFilesRequired, stemNames, stemDurationsDiffer

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudio: "Choose an unprotected WAV, AIFF, MP3, or M4A file with one or two audio channels. Apple Music subscription streams cannot be separated."
        case .tooLong: "Choose audio up to 3 minutes long. Export a shorter excerpt and try again."
        case .emptyAudio: "This file has no readable audio."
        case .modelMissing: "The on-device separation model is missing from this build."
        case .modelOutput: "The separation model returned an unexpected result. Try the audio again."
        case .fourFilesRequired: "Choose four files named vocals, drums, bass, and other."
        case .stemNames: "Name the four files vocals, drums, bass, and other so each pad gets the right track. Names must contain one role and no duplicates."
        case .stemDurationsDiffer: "The four tracks need matching durations and aligned starts. Export them together, then try again."
        }
    }
}
