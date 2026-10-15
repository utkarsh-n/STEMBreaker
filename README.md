# STEM breaker

A native SwiftUI instrument for iPhone, iOS 26 and later. Open `STEMBreaker.xcodeproj`, choose the STEMBreaker scheme, and select an iPhone. Regenerate the project with `xcodegen generate` after changing `project.yml`.

## Play

The original synthesized demo contains four independently generated tracks. Drag the colored strips to mix. Tap a channel name to mute; tap SOLO to isolate one or more channels. Seek, loop, reset, and export the current mix as a stereo WAV through Import.

## Apple Music

Library permission is requested only when you press Connect Apple Music. The app browses your on-device music library and reads/controls the Music app's shared player. No Apple Music API keys or external server are needed for this MediaPlayer integration. Your Apple Music subscription, network access and library determine playable songs.

On **iOS 27**, press **Listen to output** and approve the full display in Apple's sharing picker. ScreenCaptureKit delivers live device audio for visualization without a microphone or audio-session route changes, including Bluetooth playback. Capture can continue while you switch to Music; stop it in STEM breaker or Control Center. The analyzer requests audio only, never records/exports capture, and does not request screen samples. Availability depends on device policy and the source app. The user observed a reacting scope with Apple Music through Bluetooth headphones, but found the original visualization unhelpful; capture fidelity is not independently measured. A silent source is reported honestly; no spectrum is fabricated.

Music library APIs do not expose protected streams as PCM or original stems. Live output listening is visualization only, not an Apple Music extraction/separation path. On iOS 26, song metadata/playback and the remix deck remain available. The optional room microphone hears speakers and room noise, not digital audio inside headphones; it prefers the built-in mic while preserving an existing A2DP route when possible. Microphone mode stops in the background.

## Separate and remix files

Import unprotected WAV, M4A, MP3 or AIFF, up to 180 seconds. The bundled 38 MB Spleeter Core ML model separates vocals and accompaniment on-device. Accompaniment then undergoes harmonic/percussive signal processing and a bass crossover to produce **estimated** drums, bass and other music. These are not four independent neural stems or the original multitracks. The interface labels the session's source and method. Quality depends on the mix and can include bleed and artifacts.

For clean four-channel control, import four aligned original stems whose filenames contain `vocals`, `drums`, `bass` and `other`. Common aliases are accepted. Audio is decoded/resampled to stereo 44.1 kHz. Imports are kept in the active session; restarting loads the demo. Export a mix to keep it in Files. Export honors mute, solo and gain; samples above full scale are clipped in the 16-bit WAV.

The spectrum analyzes the actual source mix at playback position, before the phone's system output volume and route processing. Microphone analysis uses a live input tap. The app never invents Apple Music stem meters.

## See the frequencies

Spectrum has a logarithmic 20 Hz–20 kHz axis and a fixed −66 to 0 dBFS display range. Tap or drag across the plot to read a band's frequency and digital signal level. Strongest frequency is a spectral peak, not musical pitch detection. RMS reports digital level, not sound pressure at your ears. LOW/MID/HIGH show measured power shares in 20–250 Hz, 250–4000 Hz and 4000–20000 Hz bands; these are not instrument stems.

History shows up to eight seconds of measured spectra, with low frequencies at the bottom and time moving toward NOW. It freezes when deck playback pauses and resets on seeks, source/track changes and foreground return. The graph redraws when its measured data changes, so a paused deck does not run a redraw timer. Orbit remains an optional visual style. The shared 8192-point Hann FFT resolves approximately 5.9 Hz at 48 kHz, with about 85 ms of window-center delay. Analysis stays local. No checked public third-party API supplies full-song FFT timelines for arbitrary Apple Music tracks; provider research and a possible synchronized reference-file approach are documented in [Music integration](Documentation/MusicIntegration.md).

## Build and verification

- `xcodegen generate`
- `swift test --scratch-path /private/tmp/STEMBreakerCoreBuild` (pure DSP, macOS)
- Run the STEMBreaker test scheme for core tests, native audio/import checks and UI flows on Simulator.
- Apple Music account access and microphone/speaker interaction need a physical iPhone.

See [verification evidence and phone instructions](Documentation/Verification.md), the [frequency scope](Documentation/spectrum.png), and the [original deck](Documentation/deck.jpg).

## Attribution

Spleeter: Deezer, MIT, <https://github.com/deezer/spleeter>. Bundled Core ML conversion: [swift-spleeter](https://github.com/jiyimeta/swift-spleeter), MIT. Licenses ship in `App/Separation`. This independent app is inspired by tactile stem instruments and is not affiliated with STEM PLAYER, Kanye West or Apple.


## Public snapshot

See [PUBLICATION.md](PUBLICATION.md) for publication exclusions and setup requirements.
