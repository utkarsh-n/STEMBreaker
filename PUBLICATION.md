# Public source snapshot

This repository contains a reviewed source snapshot. Original Git history, credentials, personal records, local signing identities, device diagnostics, build outputs, downloaded model weights, firmware, and unreviewed media are excluded. Existing upstream license and attribution files apply to their respective components. Publication does not grant a new license to third-party content.

Configure your own Apple signing team to run native apps on a physical device. Downloaded datasets, binary runtimes, fonts, demo media, and models may need to be obtained separately using the documented upstream sources or fetch/build tools. This publication review does not certify that this snapshot builds or runs.

## Project-specific setup and exclusions

Synthesized demo WAVs and the compiled Spleeter model were excluded from the export. Restore or generate original demo stems and obtain the model from the upstream documented in `App/Separation/MODEL.md`; preserve `Spleeter-LICENSE.txt`. Loading the demo or running separation requires those resources.
