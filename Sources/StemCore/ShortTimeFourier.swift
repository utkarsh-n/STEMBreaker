import Accelerate
import Foundation

/// Unpacked real FFT spectra, including separate DC and Nyquist bins.
public struct ComplexSpectrogram: Sendable {
    public var real: [[Float]]
    public var imaginary: [[Float]]
    public var sampleCount: Int

    public init(real: [[Float]], imaginary: [[Float]], sampleCount: Int) {
        self.real = real
        self.imaginary = imaginary
        self.sampleCount = sampleCount
    }

    public var magnitudes: [[Float]] {
        zip(real, imaginary).map { vDSP.hypot($0, $1) }
    }
}

/// Centered Hann STFT. This owns its FFT plan and must stay on one worker.
public final class ShortTimeFourier {
    public let size: Int
    public let hop: Int
    private let window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>

    public init(size: Int = 4096, hop: Int = 1024) throws {
        guard size >= 4, size & (size - 1) == 0, hop > 0, hop <= size / 2,
              let fft = vDSP.FFT<DSPSplitComplex>(
                log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self
              ) else { throw FourierError.invalidConfiguration }
        self.size = size
        self.hop = hop
        self.fft = fft
        // Periodic Hann, matching torch.stft's default Hann window.
        self.window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(size))) }
    }

    public func forward(_ samples: [Float]) throws -> ComplexSpectrogram {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw FourierError.invalidSamples }
        let frameCount = (samples.count + hop - 1) / hop + 1
        let pad = size / 2
        var padded = [Float](repeating: 0, count: (frameCount - 1) * hop + size)
        padded.replaceSubrange(pad..<(pad + samples.count), with: samples)
        var realFrames = [[Float]]()
        var imagFrames = [[Float]]()
        realFrames.reserveCapacity(frameCount)
        imagFrames.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            var real = [Float](repeating: 0, count: size / 2)
            var imag = real
            let windowed = vDSP.multiply(Array(padded[(frame * hop)..<(frame * hop + size)]), window)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var complex = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                            vDSP_ctoz($0, 2, &complex, 1, vDSP_Length(size / 2))
                        }
                    }
                    fft.forward(input: complex, output: &complex)
                }
            }
            // Real vDSP FFT returns twice the conventional DFT. Unpack Nyquist from imag[0].
            let nyquist = imag[0] * 0.5
            real = vDSP.multiply(0.5, real)
            imag = vDSP.multiply(0.5, imag)
            imag[0] = 0
            real.append(nyquist)
            imag.append(0)
            realFrames.append(real)
            imagFrames.append(imag)
        }
        return ComplexSpectrogram(real: realFrames, imaginary: imagFrames, sampleCount: samples.count)
    }

    public func inverse(_ spectrum: ComplexSpectrogram) throws -> [Float] {
        let frameCount = spectrum.real.count
        guard frameCount > 0, spectrum.imaginary.count == frameCount,
              spectrum.real.allSatisfy({ $0.count == size / 2 + 1 }),
              spectrum.imaginary.allSatisfy({ $0.count == size / 2 + 1 }),
              spectrum.sampleCount > 0,
              spectrum.sampleCount <= (frameCount - 1) * hop else { throw FourierError.invalidSpectrum }
        let length = (frameCount - 1) * hop + size
        var output = [Float](repeating: 0, count: length)
        var normalization = output
        for frame in 0..<frameCount {
            var real = Array(spectrum.real[frame].prefix(size / 2))
            var imag = Array(spectrum.imaginary[frame].prefix(size / 2))
            imag[0] = spectrum.real[frame][size / 2]
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var complex = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    fft.inverse(input: complex, output: &complex)
                }
            }
            // Input spectra were divided by two; real inverse now needs 1/N.
            let scale = 1 / Float(size)
            let start = frame * hop
            for j in 0..<size {
                let sample = j.isMultiple(of: 2) ? real[j / 2] : imag[j / 2]
                output[start + j] += sample * scale * window[j]
                normalization[start + j] += window[j] * window[j]
            }
        }
        let pad = size / 2
        return (pad..<(pad + spectrum.sampleCount)).map {
            normalization[$0] > 1e-8 ? output[$0] / normalization[$0] : 0
        }
    }
}

public enum FourierError: Error, Sendable {
    case invalidConfiguration, invalidSamples, invalidSpectrum
}
