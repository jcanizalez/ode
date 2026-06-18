# ODE — Open Denoise Engine

An open-source, real-time AI noise-suppression tool for macOS — a free
alternative to Krisp. ODE captures your microphone, strips background noise
with a neural network, and (ultimately) exposes a virtual **"ODE Microphone"**
that any app (Zoom, Teams, Discord, browsers) can select.

> Status: **Phases 0–3 complete + DPDFNet engine.** Working CLI, real-time
> engine, menu-bar app with Before/After tester. Installer is next.

## How it works

```
 Real mic ──capture──► ODE Engine ──AI denoise──► clean audio ──► "ODE Microphone"
                                   DPDFNet (sherpa-onnx)              picked by any app
```

The denoising "brain" is **DPDFNet**, a full-band (48 kHz) deep-filtering speech
enhancement model, run via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
(Apache-2.0). It was chosen after an on-device bake-off against RNNoise and
GTCRN: DPDFNet removed ~28 dB of background noise while preserving ~98% of voice
energy in full-band 48 kHz, sounding the most natural — at ~7× faster than
real-time on Apple Silicon.

## Build

Requires macOS 13+ and a Swift 5.9+ toolchain.

```sh
./scripts/fetch-deps.sh    # downloads sherpa-onnx libs + DPDFNet model (~90 MB)
swift build -c release
```

## Usage (CLI)

Denoise an existing audio file:

```sh
.build/release/ode file noisy.wav clean.wav
```

Record from your mic and write raw + denoised WAVs to compare
(grant Microphone permission when prompted):

```sh
.build/release/ode mic 8 raw.wav clean.wav
```

### Measured result (DPDFNet, on a real 30 s voice clip)

| Metric | Result |
|--------|--------|
| Background noise during pauses | −28 dB |
| Voice energy retained (200 Hz–3 kHz) | ~98% |
| Speed (real-time factor) | ~0.14 (≈7× faster than real-time) |

## Roadmap

- [x] **Phase 0** — Repo scaffold, Swift package
- [x] **Phase 1** — CLI: mic/file capture → denoise → WAV
- [x] **Phase 2** — Real-time streaming engine (`ode live`) + device routing + virtual-mic setup
- [x] **Phase 3** — AppKit menu-bar app + Before/After A/B tester
- [x] **Engine upgrade** — replaced RNNoise with DPDFNet (sherpa-onnx) after an on-device bake-off
- [ ] **Phase 4** — Signed/notarized `.pkg` installer
- [ ] **Phase 5** — Acoustic echo cancellation (WebRTC APM)

## Menu-bar app

```sh
./scripts/build-app.sh     # produces dist/ODE.app (ad-hoc signed)
open dist/ODE.app          # waveform icon appears in the menu bar
```

From the menu: toggle **Denoise On/Off**, pick the **Output Device** (route into
your virtual mic), or open **Test (Before / After)…** to record a short clip and
hear it played back *with* and *without* ODE — a quick Krisp-style comparison.

## Real-time usage

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
  CSherpa/         C-API bridge to the sherpa-onnx static libraries
  ODEKit/          Shared engine library (DPDFNet denoise, audio I/O, devices, live loop)
  ode/             CLI front-end (file / mic / devices / live)
  ODEApp/          Menu-bar app (AppDelegate + Before/After tester)
third_party/sherpa/  Vendored sherpa-onnx libs + header (via scripts/fetch-deps.sh)
Resources/         DPDFNet model weights (via scripts/fetch-deps.sh)
scripts/
  fetch-deps.sh            Downloads sherpa-onnx libs + DPDFNet model
  install-virtual-mic.sh   Installs a loopback device (BlackHole)
  build-app.sh             Builds & signs dist/ODE.app
docs/
  VIRTUAL_MIC.md           Virtual-microphone setup & branded build
```

## Licensing & attribution

ODE's own code is released under the MIT License (see `LICENSE`).
Noise suppression uses **DPDFNet** via
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0), which embeds
ONNX Runtime (MIT). The virtual-microphone device is based on
[BlackHole](https://github.com/ExistentialAudio/BlackHole) (MIT).

