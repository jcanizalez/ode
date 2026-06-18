# ODE — Open Denoise Engine

An open-source, real-time AI noise-suppression tool for macOS — a free
alternative to Krisp. ODE captures your microphone, strips background noise
with a neural network, and (ultimately) exposes a virtual **"ODE Microphone"**
that any app (Zoom, Teams, Discord, browsers) can select.

> Status: **Phase 1** — working CLI denoiser. Virtual-microphone device,
> menu-bar app, and installer are on the roadmap below.

## How it works

```
 Real mic ──capture──► ODE Engine ──AI denoise──► clean audio ──► (Phase 2) "ODE Microphone"
                                   RNNoise / DeepFilterNet                    picked by any app
```

The denoising "brain" is [RNNoise](https://github.com/xiph/rnnoise) (Xiph,
BSD-licensed), a lightweight recurrent network that runs in real time on the
CPU. A future phase swaps in DeepFilterNet for higher quality.

## Build

Requires macOS 13+ and a Swift 5.9+ toolchain.

```sh
swift build -c release
```

## Usage (Phase 1 CLI)

Denoise an existing audio file:

```sh
.build/release/ode file noisy.wav clean.wav
```

Record from your mic and write raw + denoised WAVs to compare
(grant Microphone permission when prompted):

```sh
.build/release/ode mic 8 raw.wav clean.wav
```

### Measured result (synthetic speech + white noise)

| Band | Retained |
|------|----------|
| Speech (150–700 Hz) | ~99% (−0.9 dB) |
| Noise (3–20 kHz)    | ~0% (−50 dB)   |

## Roadmap

- [x] **Phase 0** — Repo scaffold, vendored RNNoise C core, Swift package
- [x] **Phase 1** — CLI: mic/file capture → RNNoise denoise → WAV
- [ ] **Phase 2** — Virtual "ODE Microphone" HAL device (BlackHole-based)
- [ ] **Phase 3** — SwiftUI menu-bar app (toggle, input picker)
- [ ] **Phase 4** — Signed/notarized `.pkg` installer
- [ ] **Phase 5** — DeepFilterNet model option for higher quality
- [ ] **Phase 6** — Acoustic echo cancellation (WebRTC APM)

## Project layout

```
Package.swift
Sources/
  CRNNoise/        Vendored RNNoise C sources + module map (the AI core)
  ode/             Swift engine + CLI
    Denoiser.swift     RNNoise wrapper
    AudioIO.swift      WAV read/write + resampling to 48 kHz mono
    MicRecorder.swift  AVAudioEngine mic capture
    main.swift         CLI entry point
```

## Licensing & attribution

ODE's own code is released under the MIT License (see `LICENSE`).
It bundles RNNoise, which is distributed under a BSD 3-Clause license
(see `Sources/CRNNoise/COPYING`). The planned virtual-microphone device is
based on [BlackHole](https://github.com/ExistentialAudio/BlackHole) (MIT).
