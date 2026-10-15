import SwiftUI
import StemCore

struct StemMixerView: View {
    var engine: RemixEngine
    @State private var feedback = 0
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TechnicalLabel(text: "TOUCH / MIX / ISOLATE")
                Spacer()
                Button("RESET") { engine.resetMix(); feedback += 1 }
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(InstrumentTheme.quiet)
                    .frame(minWidth: 44, minHeight: 28).accessibilityIdentifier("reset-mix")
            }
            HStack(spacing: 9) {
                ForEach(StemChannel.allCases, id: \.rawValue) { channel in
                    StemStrip(channel: channel, engine: engine)
                }
            }
        }.sensoryFeedback(.selection, trigger: feedback)
    }
}

private struct StemStrip: View {
    let channel: StemChannel
    var engine: RemixEngine
    @State private var notch = 10
    @State private var feedback = 0
    private var index: Int { channel.rawValue }
    private var muted: Bool { engine.muted.contains(index) }
    private var solo: Bool { engine.soloed.contains(index) }
    private var gain: Float { engine.gains[index] }

    var body: some View {
        VStack(spacing: 4) {
                Button { engine.toggleMute(index); feedback += 1 } label: {
                    VStack(spacing: 5) {
                        TechnicalLabel(text: "0\(index + 1)", color: channel.tint.opacity(0.65))
                        Text(channel.shortName).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(muted ? InstrumentTheme.background : channel.tint)
                        .background(muted ? channel.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityLabel("Mute \(channel.displayName)").accessibilityValue(muted ? "On" : "Off").accessibilityIdentifier("mute-\(index)")
            fader.frame(height: 82)
                Button { engine.toggleSolo(index); feedback += 1 } label: {
                    Text("SOLO").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(solo ? InstrumentTheme.background : channel.tint.opacity(0.6))
                        .background(solo ? channel.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityLabel("Solo \(channel.displayName)").accessibilityValue(solo ? "On" : "Off").accessibilityIdentifier("solo-\(index)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 3).frame(maxWidth: .infinity)
        .background(channel.tint.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(channel.tint.opacity(muted ? 0.06 : 0.18), lineWidth: 1) }
        .sensoryFeedback(.selection, trigger: notch).sensoryFeedback(.selection, trigger: feedback)
    }

    private var fader: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - 20)
            let y = 10 + (1 - CGFloat(gain)) * travel
            ZStack {
                Capsule().fill(channel.tint.opacity(0.1)).frame(width: 8)
                VStack { Spacer(); Capsule().fill(channel.tint.opacity(0.5)).frame(width: 4, height: max(2, CGFloat(engine.levels[index]) * travel)) }.padding(.vertical, 10)
                ForEach(0..<7) { tick in
                    Rectangle().fill(channel.tint.opacity(0.16)).frame(width: tick == 0 || tick == 6 ? 28 : 16, height: 1)
                        .position(x: geometry.size.width / 2, y: 10 + CGFloat(tick) / 6 * travel)
                }
                RoundedRectangle(cornerRadius: 5).fill(muted ? channel.tint.opacity(0.3) : channel.tint)
                    .frame(width: max(26, geometry.size.width - 24), height: 18)
                    .overlay { Capsule().fill(InstrumentTheme.background.opacity(0.4)).frame(width: 16, height: 2) }
                    .position(x: geometry.size.width / 2, y: y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let value = Float(min(1, max(0, 1 - (gesture.location.y - 10) / travel)))
                engine.setGain(value, channel: index)
                notch = Int(value * 10)
            })
        }
        .accessibilityElement().accessibilityLabel("\(channel.displayName) level").accessibilityValue("\(Int(gain * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: engine.setGain(min(1, gain + 0.1), channel: index)
            case .decrement: engine.setGain(max(0, gain - 0.1), channel: index)
            @unknown default: break
            }
            notch = Int(engine.gains[index] * 10)
        }.accessibilityIdentifier("gain-\(index)")
    }
}
