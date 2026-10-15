import SwiftUI

struct ScopeView: View {
    var deck: DeckStore
    @State private var selectedBand: Int?

    var body: some View {
        // Observe measured data in the body, then render an immutable snapshot.
        // A paused plot needs no clock or repeated redraws to stay accurate.
        let bins = deck.bandDecibels
        let centers = deck.frequencyCenters
        let orbitBins = deck.visualizer == .orbit ? deck.spectrum : []
        let history = deck.visualizer == .history ? deck.spectrumHistory : []
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                TechnicalLabel(text: deck.meterLabel, color: deck.rmsDecibels == nil ? InstrumentTheme.quiet : InstrumentTheme.accents[1])
                Spacer(minLength: 0)
                ForEach(VisualizerStyle.allCases) { style in
                    Button { deck.visualizer = style; selectedBand = nil } label: {
                        Text(style.rawValue.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(deck.visualizer == style ? InstrumentTheme.ink : InstrumentTheme.quiet)
                            .padding(.horizontal, 7).frame(minHeight: 44)
                            .background(deck.visualizer == style ? InstrumentTheme.panel : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(style.rawValue) visualizer")
                    .accessibilityIdentifier("visualizer-\(style.rawValue.lowercased())")
                    .accessibilityAddTraits(deck.visualizer == style ? .isSelected : [])
                }
            }
            GeometryReader { geometry in
                Canvas { context, size in
                    switch deck.visualizer {
                    case .spectrum: drawSpectrum(context: &context, size: size, bins: bins, centers: centers)
                    case .history: drawHistory(context: &context, size: size, history: history)
                    case .orbit: drawOrbit(context: &context, size: size, bins: orbitBins)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard deck.visualizer == .spectrum else { return }
                    let rect = plotRect(geometry.size)
                    let fraction = min(0.999, max(0, (value.location.x - rect.minX) / rect.width))
                    selectedBand = Int(fraction * 48)
                })
                .accessibilityLabel("\(deck.visualizer.rawValue) visualization")
                .accessibilityValue(deck.visualizer == .spectrum && selectedBand != nil ? frequencyReadout : deck.source == .appleMusic && !deck.microphone.isListening && !deck.outputAudio.isListening ? "Playback position only. Audio listening off." : deck.outputAudio.isListening ? "Live device output spectrum" : "Audio spectrum")
                .accessibilityHint("In Spectrum, swipe up or down to inspect frequency bands.")
                .accessibilityAdjustableAction { direction in
                    guard deck.visualizer == .spectrum else { return }
                    let delta = direction == .increment ? 1 : -1
                    selectedBand = min(47, max(0, (selectedBand ?? 24) + delta))
                }
                .accessibilityIdentifier("audio-visualization")
                if deck.source == .appleMusic && !deck.outputAudio.isListening && !deck.microphone.isListening {
                    Text("Start listening to see frequencies")
                        .font(.system(size: 11)).foregroundStyle(InstrumentTheme.quiet)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            readouts
            energyReadouts
        }
        .onChange(of: deck.source) { _, _ in selectedBand = nil }
    }

    private var readouts: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                TechnicalLabel(text: selectedBand == nil ? "STRONGEST FREQUENCY" : "FREQUENCY PROBE")
                Text(frequencyReadout)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(selectedBand == nil ? InstrumentTheme.ink : InstrumentTheme.accents[1])
                    .accessibilityIdentifier("frequency-readout")
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                TechnicalLabel(text: "RMS / DIGITAL LEVEL")
                Text(deck.rmsDecibels.map { String(format: "%.1f dBFS", $0) } ?? "— dBFS")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .accessibilityIdentifier("rms-readout")
            }
        }
    }

    private var frequencyReadout: String {
        if let band = selectedBand, deck.frequencyCenters.indices.contains(band) {
            let level = deck.bandDecibels.indices.contains(band) ? deck.bandDecibels[band] : -120
            let levelLabel = level < -66 ? "<−66" : String(format: "%.0f", level)
            return "\(frequencyLabel(deck.frequencyCenters[band])) · \(levelLabel) dBFS"
        }
        return deck.peakFrequency.map { frequencyLabel($0) } ?? "— Hz"
    }

    private var energyReadouts: some View {
        HStack(spacing: 12) {
            ForEach(0..<3) { index in
                let fraction = deck.energyDistribution.indices.contains(index) ? deck.energyDistribution[index] : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(["LOW", "MID", "HIGH"][index])
                        Spacer(minLength: 0)
                        Text("\(Int((fraction * 100).rounded()))%")
                    }.font(.system(size: 10, weight: .medium, design: .monospaced))
                    GeometryReader { geometry in
                        Capsule().fill(InstrumentTheme.quiet.opacity(0.12))
                        Capsule().fill(InstrumentTheme.accents[index])
                            .frame(width: geometry.size.width * CGFloat(max(0, min(1, fraction))))
                    }.frame(height: 3)
                    Text(["20–250 Hz", "250–4k Hz", "4k–\(frequencyLabel(deck.maximumFrequency, unit: false)) Hz"][index])
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(InstrumentTheme.quiet)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(["Low frequency power", "Mid frequency power", "High frequency power"][index])
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                .accessibilityIdentifier("band-energy-\(index)")
            }
        }.padding(.top, 5)
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 29, y: 5, width: max(1, size.width - 35), height: max(1, size.height - 24))
    }

    private func axisText(_ text: String, at point: CGPoint, context: inout GraphicsContext, anchor: UnitPoint = .center) {
        context.draw(Text(text).font(.system(size: 8, design: .monospaced)).foregroundStyle(InstrumentTheme.quiet), at: point, anchor: anchor)
    }

    private func amplitude(_ decibels: Float) -> CGFloat {
        CGFloat(max(0, min(1, (decibels + 66) / 66)))
    }

    private func xPosition(_ frequency: Double, rect: CGRect) -> CGFloat {
        rect.minX + CGFloat(log(frequency / 20) / log(deck.maximumFrequency / 20)) * rect.width
    }

    private func drawSpectrum(context: inout GraphicsContext, size: CGSize, bins: [Float], centers: [Double]) {
        let rect = plotRect(size)
        for decibels in [-60, -36, -12, 0] {
            let y = rect.maxY - CGFloat(Double(decibels + 66) / 66) * rect.height
            var line = Path(); line.move(to: CGPoint(x: rect.minX, y: y)); line.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(line, with: .color(InstrumentTheme.quiet.opacity(0.14)), lineWidth: 0.5)
            axisText("\(decibels)", at: CGPoint(x: rect.minX - 6, y: y), context: &context, anchor: .trailing)
        }
        for frequency in [20.0, 100, 1_000, deck.maximumFrequency] {
            let x = xPosition(frequency, rect: rect)
            axisText(frequencyLabel(frequency, unit: false), at: CGPoint(x: x, y: rect.maxY + 11), context: &context,
                     anchor: frequency == 20 ? .leading : frequency == deck.maximumFrequency ? .trailing : .center)
        }
        let width = rect.width / 48
        for index in 0..<min(48, bins.count) {
            let height = amplitude(bins[index]) * rect.height
            let bar = CGRect(x: rect.minX + CGFloat(index) * width + 0.5, y: rect.maxY - height, width: max(1, width - 1), height: height)
            let frequency = centers[index]
            let colorIndex = frequency < 250 ? 0 : frequency < 4_000 ? 1 : 2
            context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(InstrumentTheme.accents[colorIndex].opacity(selectedBand == index ? 1 : 0.8)))
        }
        if let index = selectedBand {
            let x = rect.minX + (CGFloat(index) + 0.5) * width
            var line = Path(); line.move(to: CGPoint(x: x, y: rect.minY)); line.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(line, with: .color(InstrumentTheme.ink), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    private func drawHistory(context: inout GraphicsContext, size: CGSize, history: [[Float]]) {
        let rect = plotRect(size)
        context.fill(Path(rect), with: .color(InstrumentTheme.panel.opacity(0.45)))
        let width = rect.width / CGFloat(DeckStore.historyCapacity)
        let height = rect.height / 48
        // Group cells into intensity levels to keep Canvas draw calls bounded.
        var paths = Array(repeating: Path(), count: 24)
        for (column, bins) in history.enumerated() {
            let x = rect.maxX - CGFloat(history.count - column) * width
            for band in 0..<min(48, bins.count) {
                let value = amplitude(bins[band])
                guard value > 0 else { continue }
                let level = min(23, Int(value * 23))
                paths[level].addRect(CGRect(x: x, y: rect.maxY - CGFloat(band + 1) * height, width: width + 0.3, height: height + 0.3))
            }
        }
        for level in 0..<24 {
            let strength = Double(level) / 23
            let color = Color(hue: 0.73 - strength * 0.62, saturation: 0.85 - strength * 0.55, brightness: 0.18 + strength * 0.82)
            context.fill(paths[level], with: .color(color))
        }
        for frequency in [100.0, 1_000, 10_000] where frequency < deck.maximumFrequency {
            let fraction = log(frequency / 20) / log(deck.maximumFrequency / 20)
            let y = rect.maxY - CGFloat(fraction) * rect.height
            axisText(frequencyLabel(frequency, unit: false), at: CGPoint(x: rect.minX - 5, y: y), context: &context, anchor: .trailing)
        }
        axisText("−8s", at: CGPoint(x: rect.minX, y: rect.maxY + 11), context: &context, anchor: .leading)
        axisText("TIME →", at: CGPoint(x: rect.midX, y: rect.maxY + 11), context: &context)
        axisText("NOW", at: CGPoint(x: rect.maxX, y: rect.maxY + 11), context: &context, anchor: .trailing)
        if history.isEmpty && deck.source == .deck {
            axisText("Play to build frequency history", at: CGPoint(x: rect.midX, y: rect.midY), context: &context)
        }
    }

    private func drawOrbit(context: inout GraphicsContext, size: CGSize, bins: [Float]) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.height, size.width) * 0.3
        for ring in 0..<3 {
            let r = radius * (0.56 + Double(ring) * 0.22)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(InstrumentTheme.quiet.opacity(0.16)), lineWidth: 1)
        }
        for (index, value) in bins.prefix(48).enumerated() {
            let angle = Double(index) / 48 * .pi * 2 - .pi / 2
            let amplitude = Double(max(0, min(1, value)))
            let outer = radius + amplitude * radius * 0.55
            var ray = Path()
            ray.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.8, y: center.y + sin(angle) * radius * 0.8))
            ray.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            context.stroke(ray, with: .color(InstrumentTheme.accents[index / 12].opacity(0.25 + amplitude * 0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        context.draw(Text("SB").font(.system(size: 28, weight: .ultraLight, design: .rounded)).foregroundStyle(InstrumentTheme.ink), at: center)
    }

    private func frequencyLabel(_ frequency: Double, unit: Bool = true) -> String {
        let value = frequency >= 1_000 ? String(format: frequency >= 10_000 ? "%.0fk" : "%.1fk", frequency / 1_000) : String(format: "%.0f", frequency)
        return unit ? "\(value) Hz" : value
    }
}
