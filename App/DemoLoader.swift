import Foundation
import StemCore

/// Loads bundled original stems off the UI thread; synthesis is only a build-time tool.
enum DemoLoader {
    static func load() async throws -> StemSession {
        let worker = Task.detached(priority: .userInitiated) {
            let names = ["vocals", "drums", "bass", "other"]
            var channels = [StereoSamples]()
            for name in names {
                try Task.checkCancellation()
                guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Demo") else {
                    throw DemoError.missingAsset
                }
                channels.append(try AudioImporter.decode(url))
            }
            return try StemSession(
                title: "Neon Circuit",
                sampleRate: AudioImporter.sampleRate,
                channels: channels,
                provenance: "Original synthesized demo • Four independently generated tracks. The vocals pad plays a voice-like synth."
            ).validated()
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private enum DemoError: Error, LocalizedError {
        case missingAsset
        var errorDescription: String? { "The original demo audio is missing from this build." }
    }
}
