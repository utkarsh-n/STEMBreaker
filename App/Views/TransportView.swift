import SwiftUI

struct TransportView: View {
    var deck: DeckStore
    @State private var scrubTime = 0.0
    @State private var scrubbing = false
    @State private var feedback = 0

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { scrubbing ? scrubTime : min(deck.position, max(0.01, deck.duration)) }, set: { scrubTime = $0 }), in: 0...max(0.01, deck.duration)) { editing in
                if editing { scrubTime = deck.position }
                scrubbing = editing
                if !editing { deck.seek(scrubTime) }
            }
            .tint(InstrumentTheme.ink).accessibilityLabel("Playback position").accessibilityValue(timecode(scrubbing ? scrubTime : deck.position)).accessibilityIdentifier("playback-position")
            HStack {
                TechnicalLabel(text: timecode(scrubbing ? scrubTime : deck.position))
                Spacer()
                if deck.source == .deck {
                    Button { deck.engine.loopEnabled.toggle(); feedback += 1 } label: {
                        Image(systemName: "repeat").foregroundStyle(deck.engine.loopEnabled ? InstrumentTheme.accents[1] : InstrumentTheme.quiet).frame(width: 48, height: 48)
                    }.accessibilityLabel("Loop").accessibilityValue(deck.engine.loopEnabled ? "On" : "Off").accessibilityIdentifier("loop-toggle")
                } else { Color.clear.frame(width: 48, height: 48) }
                Button {
                    if deck.source == .appleMusic { deck.music.skipPrevious() } else { deck.seek(max(0, deck.position - 15)) }
                    feedback += 1
                } label: { Image(systemName: deck.source == .deck ? "gobackward.15" : "backward.end.fill").frame(width: 44, height: 48) }
                    .accessibilityLabel(deck.source == .deck ? "Back 15 seconds" : "Previous song")
                Button { deck.togglePlayback(); feedback += 1 } label: {
                    Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 58, height: 48)
                        .foregroundStyle(InstrumentTheme.background).background(InstrumentTheme.ink, in: Capsule())
                }.accessibilityLabel(deck.isPlaying ? "Pause" : "Play").accessibilityIdentifier("play-toggle")
                Button {
                    if deck.source == .appleMusic { deck.music.skipNext() } else { deck.seek(min(deck.duration, deck.position + 15)) }
                    feedback += 1
                } label: { Image(systemName: deck.source == .deck ? "goforward.15" : "forward.end.fill").frame(width: 44, height: 48) }
                    .accessibilityLabel(deck.source == .deck ? "Forward 15 seconds" : "Next song")
                Spacer()
                TechnicalLabel(text: "−" + timecode(max(0, deck.duration - deck.position)))
            }.buttonStyle(.plain)
        }.sensoryFeedback(.selection, trigger: feedback)
    }
}
