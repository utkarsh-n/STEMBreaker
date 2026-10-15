# Local separation model

`Models/Spleeter2Model.mlmodelc` is the compiled 2-source Core ML Spleeter model distributed by `jiyimeta/swift-spleeter` (downloaded 2026-10-11, commit `bb101655260b2262fe84d3f6b9478a9812884faa`).

Source: https://github.com/jiyimeta/swift-spleeter
Upstream model: https://github.com/deezer/spleeter
License: MIT. The complete Kiichi Ito and Deezer notices are in `Spleeter-LICENSE.txt` and must travel with the application.

The model accepts 44.1 kHz stereo STFT magnitudes: `[2, 1024, 216]`, 4096-sample periodic Hann windows with 1024-sample hop. Its outputs are vocals and accompaniment masks. It does **not** predict four independent instrument sources.

STEM Breaker reconstructs stereo vocals using a normalized two-source mask, preserves the full-band mixture complement as accompaniment, and divides accompaniment into drums/bass/other using median-filter harmonic/percussive estimation plus a 220 Hz harmonic bass crossover. High frequencies above the model's approximately 11 kHz analysis range stay in accompaniment. All four pads together reconstruct the decoded source. Results can bleed between instruments.

Inference runs in fixed ~5-second windows with ~93 ms overlap, uses no server, checks cancellation between windows and DSP frames, and accepts at most 180 seconds. Four supplied stems bypass inference and estimation and are assigned by role words in filenames. File start alignment must be ensured by the user.

`ShortTimeFourier` and `SpleeterSeparator` were independently adapted from the documented upstream tensor shape and algorithm. The STFT corrects vDSP real-FFT scaling and packs DC/Nyquist independently. The original Swift implementation's license is retained alongside the model.
