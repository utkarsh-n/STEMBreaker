import Accelerate
import CoreML
import Foundation
import StemCore

/// Runs the bundled Deezer Spleeter 2-source network entirely on this device.
/// The network predicts vocals/accompaniment masks through ~11 kHz. High-frequency
/// mixture content stays in accompaniment; accompaniment is then split by DSP estimates.
final class SpleeterSeparator {
    private let model: MLModel
    private let transform: ShortTimeFourier
    private let windowSamples = 215 * 1024
    private let modelFrames = 216
    private let modelBins = 1024

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        transform = try ShortTimeFourier(size: 4096, hop: 1024)
    }

    func separate(_ input: StereoSamples, progress: @escaping @Sendable (Double, String) -> Void) throws -> [StereoSamples] {
        let count = input.count
        guard count > 0, input.left.count == input.right.count else { throw SeparationError.emptyAudio }
        var tracks = (0..<4).map { _ in StereoSamples(left: [Float](repeating: 0, count: count), right: [Float](repeating: 0, count: count)) }
        var accumulatedWeight = [Float](repeating: 0, count: count)
        let overlap = 4096
        let stride = windowSamples - overlap
        let numberOfChunks = count <= windowSamples ? 1 : 1 + (count - windowSamples + stride - 1) / stride
        for chunkIndex in 0..<numberOfChunks {
            try Task.checkCancellation()
            let start = chunkIndex * stride
            let end = min(count, start + windowSamples)
            let actualLength = end - start
            progress(0.08 + 0.85 * Double(chunkIndex) / Double(numberOfChunks), "Separating window \(chunkIndex + 1) of \(numberOfChunks)")
            let separated: [StereoSamples] = try autoreleasepool {
                let left = Array(input.left[start..<end]) + [Float](repeating: 0, count: windowSamples - actualLength)
                let right = Array(input.right[start..<end]) + [Float](repeating: 0, count: windowSamples - actualLength)
                let spectra = try [transform.forward(left), transform.forward(right)]
                let magnitude = try MLMultiArray(shape: [2, NSNumber(value: modelBins), NSNumber(value: modelFrames)], dataType: .float32)
                let pointer = magnitude.dataPointer.assumingMemoryBound(to: Float.self)
                let strides = magnitude.strides.map(\.intValue)
                for channel in 0..<2 {
                    for frame in 0..<modelFrames {
                        for bin in 0..<modelBins {
                            pointer[channel * strides[0] + bin * strides[1] + frame * strides[2]] = hypot(spectra[channel].real[frame][bin], spectra[channel].imaginary[frame][bin])
                        }
                    }
                }
                let provider = try MLDictionaryFeatureProvider(dictionary: ["magnitude": MLFeatureValue(multiArray: magnitude)])
                let prediction = try model.prediction(from: provider)
                guard let vocalMask = prediction.featureValue(for: "vocalsMask")?.multiArrayValue,
                      let accompanimentMask = prediction.featureValue(for: "accompanimentMask")?.multiArrayValue else { throw SeparationError.modelOutput }
                let vocalValues = try floats(vocalMask)
                let accompanimentValues = try floats(accompanimentMask)
                let maskStrides = vocalMask.strides.map(\.intValue)
                guard vocalMask.shape.map(\.intValue) == [2, modelBins, modelFrames, 1],
                      accompanimentMask.shape == vocalMask.shape else { throw SeparationError.modelOutput }
                var vocalChannels = [[Float]]()
                var accompanimentChannels = [[Float]]()
                for channel in 0..<2 {
                    var vocalSpectrum = spectra[channel]
                    for frame in 0..<modelFrames {
                        for bin in 0...transform.size / 2 {
                            var vocalRatio: Float = 0
                            if bin < modelBins {
                                let index = channel * maskStrides[0] + bin * maskStrides[1] + frame * maskStrides[2]
                                let vocal = max(0, vocalValues[index])
                                let accompaniment = max(0, accompanimentValues[index])
                                let sum = vocal + accompaniment
                                if sum.isFinite, sum > 1e-8 { vocalRatio = vocal / sum }
                            }
                            vocalSpectrum.real[frame][bin] *= vocalRatio
                            vocalSpectrum.imaginary[frame][bin] *= vocalRatio
                        }
                    }
                    let vocals = Array(try transform.inverse(vocalSpectrum).prefix(actualLength))
                    vocalChannels.append(vocals)
                    // Exact complement preserves full-band source reconstruction, independent of mask normalization.
                    let source = channel == 0 ? left : right
                    accompanimentChannels.append((0..<actualLength).map { source[$0] - vocals[$0] })
                }
                let accompaniment = StereoSamples(left: accompanimentChannels[0], right: accompanimentChannels[1])
                let estimated = try InstrumentEstimator.split(accompaniment, sampleRate: 44_100)
                return [StereoSamples(left: vocalChannels[0], right: vocalChannels[1])] + estimated
            }
            for offset in 0..<actualLength {
                let globalIndex = start + offset
                var weight: Float = 1
                if start > 0, offset < overlap { weight *= Float(offset) / Float(overlap) }
                if end < count, offset >= actualLength - overlap { weight *= Float(actualLength - offset) / Float(overlap) }
                accumulatedWeight[globalIndex] += weight
                for track in 0..<4 {
                    tracks[track].left[globalIndex] += separated[track].left[offset] * weight
                    tracks[track].right[globalIndex] += separated[track].right[offset] * weight
                }
            }
        }
        for frame in 0..<count {
            let weight = max(1e-8, accumulatedWeight[frame])
            for track in 0..<4 {
                tracks[track].left[frame] /= weight
                tracks[track].right[frame] /= weight
            }
        }
        return tracks
    }

    /// Model output is currently fp32. Convert fp16/double explicitly for future model compiler versions.
    private func floats(_ array: MLMultiArray) throws -> [Float] {
        switch array.dataType {
        case .float32:
            return Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: array.count))
        case .float16:
            return Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float16.self), count: array.count)).map(Float.init)
        case .double:
            return Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Double.self), count: array.count)).map(Float.init)
        default:
            throw SeparationError.modelOutput
        }
    }
}
