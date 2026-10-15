import SwiftUI

struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("An instrument for taking music apart") {
                    Label("Drag a strip to change its level.", systemImage: "slider.vertical.3")
                    Label("Tap a channel name to mute. SOLO isolates one or more layers.", systemImage: "speaker.wave.2")
                    Label("Loop a session, seek, then share your mix as WAV.", systemImage: "repeat")
                }
                Section("Apple Music") {
                    Text("Connect your library to see song artwork, artist, playback position and control the Music app’s player.")
                    Text("On iOS 27, Listen to output opens Apple’s system sharing picker. Approve the full display to visualize audio supplied by the system, including with Bluetooth headphones. It does not use the microphone or save screen images. Stop listening in the app or in Control Center.")
                    Text("Music library APIs provide song details, not audio samples. System output capture depends on the source app; protected playback may be unavailable. If the scope is silent, use an unprotected file in the remix deck. Live output listening is visualization only.")
                    Text("The optional room microphone visualizes sound around your phone, including room noise. It cannot hear audio inside headphones. Imported files are analyzed directly and work with any output route.")
                }
                Section("Reading the scope") {
                    Text("Spectrum shows low frequencies on the left and high frequencies on the right. Tap or drag across it to inspect a frequency band. The vertical axis is dBFS: digital signal level relative to full scale, not the volume at your ears.")
                    Text("History keeps the last eight seconds of measured spectra. Bass is at the bottom, treble at the top; brighter cells mean stronger sound. Playback pauses freeze the deck’s history.")
                    Text("Strongest frequency identifies a spectral peak, not a musical note or key. LOW, MID and HIGH show shares of measured frequency-band power, not separate instruments or stems.")
                }
                Section("Breaking an imported file") {
                    Text("Spleeter separates vocals and accompaniment using an on-device neural model. The accompaniment is split into estimated drum transients, bass and other music using signal processing.")
                    Text("Only the vocal/accompaniment split uses AI. The three instrument layers overlap in musical content and are estimates, not original multitracks. Separation can leave artifacts and bleed.")
                    Text("Import up to three minutes of unprotected audio. Four original stems produce the cleanest deck: name your aligned files vocals, drums, bass and other.")
                }
                Section("Your audio stays here") {
                    Text("Files, output audio and microphone input are analyzed locally. Live input is not saved or uploaded; screen samples are not requested. Apple Music is used for its library and playback. System capture continues when you switch apps until you stop it.")
                }
                Section("Credits") {
                    Text("Original synthesized demo by STEM breaker. Not affiliated with STEM PLAYER or its creators.")
                    Link("Spleeter · Deezer · MIT", destination: URL(string: "https://github.com/deezer/spleeter")!)
                    Link("Swift Spleeter model conversion · MIT", destination: URL(string: "https://github.com/jiyimeta/swift-spleeter")!)
                }
            }
            .font(.subheadline).navigationTitle("Inside STEM breaker").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(InstrumentTheme.accents[1])
    }
}
