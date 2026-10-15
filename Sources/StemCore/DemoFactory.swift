import Foundation

public enum DemoFactory {
    /// Four independently synthesized tracks: a formant lead, drums, bass, and chords.
    /// No copyrighted recording or external audio is included.
    public static func makeDemo() -> StemSession {
        let rate = 44_100.0
        let duration = 24.0
        let count = Int(rate * duration)
        var tracks = (0..<4).map { _ in StereoSamples(left: [Float](repeating: 0, count: count), right: [Float](repeating: 0, count: count)) }
        let beat = 0.6
        let melody = [69, 72, 76, 72, 67, 69, 72, 64, 65, 69, 72, 69, 67, 71, 74, 71]
        let roots = [45, 41, 48, 43]
        var random: UInt64 = 0x5354454D42524541
        for i in 0..<count {
            let t = Double(i) / rate
            let beatIndex = Int(t / beat)
            let beatTime = t.truncatingRemainder(dividingBy: beat)
            let eighthTime = t.truncatingRemainder(dividingBy: beat / 2)
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double((random >> 40) & 0xFFFFFF) / Double(0xFFFFFF) * 2 - 1
            let fade = min(1, t / 0.08) * min(1, (duration - t) / 0.7)

            // Pitch sweep plus a short click makes the kick palpable through the bass stem.
            let kickPhase = 2 * .pi * (48 * beatTime + 75 * 0.025 * (1 - exp(-beatTime / 0.025)))
            let kick = 0.25 * sin(kickPhase) * exp(-beatTime * 16)
            let snare = beatIndex.isMultiple(of: 2) ? 0 : 0.14 * noise * exp(-beatTime * 27)
            let hat = 0.04 * noise * exp(-eighthTime * 95)
            let drums = (kick + snare + hat) * fade
            tracks[1].left[i] = Float(drums)
            tracks[1].right[i] = Float(drums * 0.96 + hat * 0.25)

            let root = roots[(beatIndex / 8) % roots.count]
            let bassFrequency = frequency(root)
            let bassEnvelope = min(1, beatTime / 0.008) * exp(-beatTime * 2.7)
            let bass = (0.125 * sin(2 * .pi * bassFrequency * t) + 0.026 * sin(4 * .pi * bassFrequency * t)) * bassEnvelope * fade
            tracks[2].left[i] = Float(bass)
            tracks[2].right[i] = Float(bass)

            let note = melody[beatIndex % melody.count]
            let fundamental = frequency(note) * (1 + 0.004 * sin(2 * .pi * 5.4 * t))
            let leadEnvelope = min(1, beatTime / 0.04) * min(1, (beat - beatTime) / 0.08)
            var lead = 0.0
            for harmonic in 1...10 {
                let f = Double(harmonic) * fundamental
                let formant = 0.3 + 0.8 * exp(-pow((f - 730) / 260, 2)) + 0.45 * exp(-pow((f - 1_250) / 340, 2))
                lead += sin(2 * .pi * f * t) * formant / Double(harmonic)
            }
            lead *= 0.08 * leadEnvelope * fade
            if beatIndex % 8 >= 6 { lead *= 0.25 }
            tracks[0].left[i] = Float(lead)
            tracks[0].right[i] = Float(lead * 0.94)

            let chordTime = t.truncatingRemainder(dividingBy: beat * 2)
            let chordEnvelope = min(1, chordTime / 0.02) * exp(-chordTime * 2)
            let intervals = [12, 15, 19, 24]
            var chordLeft = 0.0
            var chordRight = 0.0
            for (index, interval) in intervals.enumerated() {
                let f = frequency(root + interval)
                let level = 0.04 / Double(index + 1)
                chordLeft += level * sin(2 * .pi * f * t)
                chordRight += level * sin(2 * .pi * (f * 1.002) * t + Double(index) * 0.35)
            }
            tracks[3].left[i] = Float(chordLeft * chordEnvelope * fade)
            tracks[3].right[i] = Float(chordRight * chordEnvelope * fade)
        }
        var session = StemSession(title: "Neon Circuit", sampleRate: rate, channels: tracks,
                                  provenance: "Original synthesized demo • Four independently generated tracks. The vocals pad plays a voice-like synth.")
        let mix = StemMixer.mix(session)
        let peak = max(mix.left.map { abs($0) }.max() ?? 0, mix.right.map { abs($0) }.max() ?? 0)
        if peak > 0.85 {
            let scale = 0.85 / peak
            session.channels = tracks.map { StereoSamples(left: $0.left.map { $0 * scale }, right: $0.right.map { $0 * scale }) }
        }
        return session
    }

    private static func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
}
