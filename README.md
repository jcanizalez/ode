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
- [x] **Phase 2** — Real-time streaming engine (`ode live`) + device routing + virtual-mic setup
- [x] **Phase 3** — SwiftUI/AppKit menu-bar app + Before/After A/B tester
- [ ] **Phase 4** — Signed/notarized `.pkg` installer
- [ ] **Phase 5** — DeepFilterNet model option for higher quality
- [ ] **Phase 6** — Acoustic echo cancellation (WebRTC APM)

## Menu-bar app (Phase 3)

```sh
./scripts/build-app.sh     # produces dist/ODE.app (ad-hoc signed)
open dist/ODE.app          # waveform icon appears in the menu bar
```

From the menu: toggle **Denoise On/Off**, pick the **Output Device** (route into
your virtual mic), or open **Test (Before / After)…** to record a short clip and
hear it played back *with* and *without* ODE — a quick Krisp-style comparison.

## Real-time usage (Phase 2)

Install the virtual microphone, then run the live denoiser into it:

```sh
./scripts/install-virtual-mic.sh         # installs a loopback device
ode live --out "BlackHole 2ch"           # mic -> denoise -> virtual device
# pick that device as your mic in Zoom/Teams/Discord/browser
```

`ode devices` lists everything CoreAudio sees. See `docs/VIRTUAL_MIC.md` for
the branded "ODE Microphone" build.

## Project layout

```
Package.swift
Sources/
  CRNNoise/        Vendored RNNoise C sources + module map (the AI core)
  ODEKit/          Shared engine library (denoise, audio I/O, devices, live loop)
  ode/             CLI front-end (file / mic / devices / live)
  ODEApp/          Menu-bar app (AppDelegate + Before/After tester)
scripts/
  install-virtual-mic.sh   Installs a loopback device (BlackHole)
  build-app.sh             Builds & signs dist/ODE.app
docs/
  VIRTUAL_MIC.md           Virtual-microphone setup & branded build
```

## Licensing & attribution

ODE's own code is released under the MIT License (see `LICENSE`).
It bundles RNNoise, which is distributed under a BSD 3-Clause license
(see `Sources/CRNNoise/COPYING`). The planned virtual-microphone device is
based on [BlackHole](https://github.com/ExistentialAudio/BlackHole) (MIT).
