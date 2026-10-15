# Apple Music integration and stem sources

STEM Breaker uses the public MediaPlayer system music player to display and control the song playing in the iPhone Music app. The user grants library permission from the Connect Apple Music action. The application must include `NSAppleMusicUsageDescription`. Nothing creates the system player or queries the library before permission is authorized.

`MPMusicPlayerController.systemMusicPlayer` explicitly shares the Music app's now-playing item and playback state. The bridge reads `nowPlayingItem`, `currentPlaybackTime`, artwork, and duration; observes now-playing, transport, and library changes; and refreshes the playhead while the app is visible. Its observers and timer use weak references, and the owning screen stops observation when inactive. Apple Music integration requires a physical iPhone and the user's account; simulator presentation alone cannot verify it.

- [Apple: system music player and shared state](https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/systemmusicplayer)
- [Apple: MediaPlayer library permission and playback](https://developer.apple.com/documentation/mediaplayer)
- [Apple: generating playback notifications](https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/begingeneratingplaybacknotifications())
- [Apple: authorization request and purpose string](https://developer.apple.com/documentation/musickit/musicauthorization/request())

## Audio access is distinct from playback access

The public MusicKit and MediaPlayer interfaces expose metadata and playback control. They do not expose an Apple Music PCM stream to this app's audio engine. Apple's documented protected-asset property identifies DRM-protected media that cannot play through a standard playback API. An Apple Music subscription or an offline Music download does not supply remixable stems through this bridge. This MusicKit limitation must not be confused with the separate, user-consented ScreenCaptureKit capture API added to iPhone in iOS 27.

The Apple Music deck must identify which source supplies its visualization: artwork/progress, microphone input, approved live system output, or a decoded local file. It can show measured frequency analysis only while real audio samples are arriving from that source. Frequency analysis does not imply isolated instruments or remixable stems. Neural separation and stem mixing operate on imported, readable audio files or supplied individual stem files.

- [Apple: protected-asset property](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/hasprotectedasset)
- [Apple: protected assets cannot play through standard playback APIs](https://developer.apple.com/documentation/mediaplayer/general-media-item-property-keys)
- [Apple: assetURL and AVFoundation](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/asseturl)
- [Apple: MusicKit supported metadata and players](https://developer.apple.com/documentation/musickit)

## iOS 27 live system output

ScreenCaptureKit is a public iOS 27 API for streaming screen content and audio into `CMSampleBuffer` objects. Its `SCStreamConfiguration.capturesAudio` property enables audio output, and `SCStreamOutputType.audio` delivers audio samples independently of the microphone output. This provides a supported general capture path that does not rely on sound reaching a microphone, including when the user is listening through headphones. Availability of a particular playback source or route still requires physical-device verification.

On iPhone, the system picker offers full-display capture or capture of the current app. The macOS APIs for programmatically including or excluding specific third-party applications are unavailable on iOS. A device-output visualizer therefore requests full-display capture through `SCContentSharingPicker`; selecting in-app capture would restrict the stream to STEM Breaker. The app should keep microphone and camera controls off for this mode, attach only an audio stream output, and analyze the samples in memory. It does not need to save a screen recording or request Photos access for a live spectrum.

The ScreenCaptureKit documentation requests `NSScreenCaptureUsageDescription` and the system capture permission flow. Apple's iOS sample declares `screen-capture` in `UIBackgroundModes` so full-display capture survives backgrounding. Its additional `audio` background mode and `AVAudioSession.playAndRecord` setup support the sample's microphone tap; they are not a reason to activate a microphone in an output-only visualizer. `NSAudioCaptureUsageDescription` is documented for macOS Core Audio taps, not this iPhone capture path. No persistent-content-capture entitlement or ReplayKit broadcast extension is required for the ordinary system picker flow documented here.

Full-display capture is the appropriate request while the system Music player continues playback and STEM Breaker is foreground. However, Apple's current documentation does not promise that protected Apple Music playback supplies usable audio buffers. Some sources may prohibit recording, return silence, stop playback, or be unavailable. The app must show an honest waiting, silent, interrupted, or unavailable state and must not synthesize a spectrum when capture provides no usable samples. Captured output is a visualization source, not permission to decrypt, isolate, or export protected Apple Music songs. Apple Music playback, Bluetooth capture behavior, capture cancellation, and returning from background remain separate device scenarios to verify.

Do not make the opposite blanket claim that all DRM audio is automatically silenced: Apple's archived FairPlay capture guidance says its automatic exclusion applies to video and describes an application response for audio. That historical behavior does not establish current Apple Music capture support. The supported claim is general user-consented iOS 27 capture, with source-specific behavior left to runtime verification.

- [Apple: ScreenCaptureKit overview and purpose string](https://developer.apple.com/documentation/screencapturekit?changes=latest_be_8)
- [Apple: iOS 27 sample, picker modes, and background capture](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)
- [Apple: enabling captured audio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- [Apple: background mode values, including screen-capture](https://developer.apple.com/documentation/BundleResources/Information-Property-List/UIBackgroundModes?changes=la)
- [Apple: macOS audio capture purpose string](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [Apple: iPhone screen-recording restrictions](https://support.apple.com/en-ie/102653)
- [Apple: archived FairPlay screen-capture guidance](https://developer.apple.com/library/archive/qa/qa1970/_index.html)

The installed iPhoneOS 27 SDK independently marks `SCStreamOutputType.audio`, `capturesAudio`, and the picker as available in iOS 27. Its `SCContentFilter` application-selection initializers are explicitly unavailable on iOS. Core Audio process taps remain a macOS API; they are not the iPhone solution.

- [Apple: Core Audio process taps require macOS](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)

## File-backed visualization fallback

Readable local files are the most predictable route-independent source. An authorized library item is eligible only when `hasProtectedAsset` is false, `assetURL` exists, and AVFoundation reports an unprotected, readable asset and successfully decodes its audio. `assetURL` may use the `ipod-library` scheme, so create an `AVURLAsset` rather than assuming it is a normal file URL usable by `AVAudioFile`. Use `AVAssetReader` with an audio-track output configured for linear PCM, and cancel obsolete work when the now-playing item's persistent identifier changes. A cloud item or downloaded subscription item must not be assumed readable based on download state alone.

A cached waveform or spectrum derived from such a file can follow `systemMusicPlayer.currentPlaybackTime`. Label it as synced file analysis: it describes the local file around the observed playhead, not a tap of Music's actual output, effects, hardware volume, or Bluetooth processing. Seeking, track changes, and pauses must update that synchronization. The app's own imported remix deck can instead analyze its own mixed samples or engine output directly; both approaches continue to work without a microphone.

iOS 27's Music Understanding framework accepts an `AVAsset` or audio buffers supplied by the app, and can add rhythm, loudness, structure, and instrument-activity analysis. It does not create a MusicKit audio tap. Its documented `hasProtectedContent` error explicitly rejects DRM-protected assets that cannot be decoded for analysis.

- [Apple: media-library asset URL scheme](https://developer.apple.com/documentation/mediaplayer/mpmediaitempropertyasseturl)
- [Apple: readable assets and sample extraction](https://developer.apple.com/documentation/avfoundation/avasset/isreadable)
- [Apple: track output and linear PCM audio](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput)
- [Apple: Music Understanding audio inputs](https://developer.apple.com/documentation/musicunderstanding)
- [Apple: DRM-protected analysis error](https://developer.apple.com/documentation/musicunderstanding/musicunderstandingerror/hasprotectedcontent)

## Third-party analysis

Among the checked public APIs, none provides an accessible full-track FFT or frequency-band time series for an arbitrary Apple Music song. Track-level tempo, key, energy, and instrument tags cannot reconstruct its changing spectrum. Precomputed analysis synchronized to a playhead also differs from measuring live device output.

Spotify's Audio Analysis endpoint supplies full-track beat/bar times and timed segments with loudness, 12 pitch-class values, and 12 timbre coefficients. Pitch classes fold pitches across octaves; timbre coefficients are abstract descriptors, not frequency bins. The endpoint is marked deprecated, and Spotify's November 2024 change removes access for new use cases while preserving qualifying existing extended-mode integrations. Policy III.5 explicitly prohibits products integrated with another service's streams or content. That creates a direct constraint for an Apple Music integration; an existing credential must not be treated as permission for this use case.

- [Spotify: Audio Analysis response schema](https://developer.spotify.com/documentation/web-api/reference/get-audio-analysis)
- [Spotify: access change and existing-app exception](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api)
- [Spotify: Developer Policy, section III](https://developer.spotify.com/policy)

Cyanite exposes timestamped instrument-presence scores through `InstrumentsV2.segments`, along with segment-level BPM, key, mood, and section boundaries. These predictions could drive a cached instrument/structure timeline, but its public models do not expose FFT bins or individual beat-event timestamps. Its documented workflow requires supplying an audio file, asynchronous preprocessing, and API access; it does not supply the protected Apple Music recording. ReccoBeats offers catalog summary features without authentication, while its upload-analysis endpoint returns scalar features and truncates input beyond 30 seconds. Neither is a live-frequency source.

- [Cyanite: current model outputs and timestamps](https://docs.cyanite.ai/docs/guides/model-outputs/)
- [Cyanite: upload and asynchronous analysis workflow](https://docs.cyanite.ai/docs/intro/)
- [ReccoBeats: catalog audio features](https://reccobeats.com/docs/apis/get-track-audio-features)
- [ReccoBeats: upload response and 30-second limit](https://reccobeats.com/docs/documentation/Analysis/audio-features-extraction)
- [ReccoBeats: authentication and access terms](https://reccobeats.com/docs/documentation/terms-of-service)

A future option is to precompute timestamped spectra from an explicitly matched, readable reference file, cache the results by file identity, and follow the observed Music playhead. Matching must cover the exact recording, edit, master, duration, and any leading silence; title/artist or a preview clip alone cannot establish full-track alignment. Pauses, seeks, and track changes require resynchronization. Bluetooth and other routes can change audible delay, so validate alignment against playback rather than assuming one fixed offset. Label this as reference-file analysis synchronized to playback: it will not reflect Music's current processing, hardware volume, or output-route changes. No third-party contract or special permission for this future option is assumed here.

## On-device neural separation research

[Deezer Spleeter](https://github.com/deezer/spleeter) supplies pretrained two-, four-, and five-source models. Its [published paper](https://doi.org/10.21105/joss.02154) states that code and pretrained models are MIT licensed. The original four-source model provides vocals, drums, bass, and other. Model redistribution should preserve Deezer's copyright and MIT license.

[swift-spleeter](https://github.com/jiyimeta/swift-spleeter) is an MIT Swift/Core ML implementation with async progress, streamed file processing, and an included compiled two-source demo model. Its current output is monaural. Four- and five-source operation require supplying compiled models; they are not included in the package. Its upstream [Core ML converter](https://github.com/fwcd/spleeter-pytorch) exports the non-FFT network and requires STFT and inverse STFT outside Core ML. That converter is only tested with the two-source model and notes quality differences from the original, so a four-source port needs validation against the reference before the app can call its output neural stems.

Demucs is technically another possibility, but its source-code license must not be confused with its weights: the [original author's model-license statement](https://github.com/facebookresearch/demucs/issues/327) says the weights are not covered by MIT and are supplied for scientific purposes. Community conversion repositories claiming all weights are MIT do not resolve that original licensing statement.

Without a validated neural model, frequency-band filtering or mid/side extraction is useful audio decomposition, but should be labeled spectral layers or approximate separation. It cannot honestly be presented as isolated vocals, drums, bass, and instruments. Authentic four-fader stem performance remains available for individual stem-file imports and the bundled multitrack demo.
