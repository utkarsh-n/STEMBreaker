// Build together with Sources/StemCore/StemSession.swift and DemoFactory.swift using swiftc -O.
import AVFoundation
import Foundation

@main
struct GenerateDemo {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw GeneratorError.outputDirectoryRequired
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = Date()
        let session = try DemoFactory.makeDemo().validated()
        print("Generated \(session.duration)s of original four-track audio in \(Date().timeIntervalSince(started))s")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: session.sampleRate, channels: 2, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: session.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        for (index, name) in ["vocals", "drums", "bass", "other"].enumerated() {
            let track = session.channels[index]
            let url = folder.appendingPathComponent(name).appendingPathExtension("wav")
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(track.count))!
            buffer.frameLength = AVAudioFrameCount(track.count)
            track.left.withUnsafeBufferPointer { pointer in
                buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: track.count)
            }
            track.right.withUnsafeBufferPointer { pointer in
                buffer.floatChannelData![1].update(from: pointer.baseAddress!, count: track.count)
            }
            try file.write(from: buffer)
            print("Wrote \(name).wav, \(track.count) stereo frames")
        }
        print("Total generation/export time: \(Date().timeIntervalSince(started))s")
    }

    enum GeneratorError: Error { case outputDirectoryRequired }
}
