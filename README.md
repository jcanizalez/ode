# ODE — an ode to your voice

**ODE** is named after the *ode* — a lyric poem written in celebration of
something. This one is a celebration of **your voice**: an open-source,
real-time AI meeting companion for macOS. It removes background noise in both
directions, transcribes and summarizes your meetings, and answers questions
about them — **entirely on-device**. Nothing you say ever leaves your Mac.

*(ODE also happens to stand for **Open Denoise Engine** — open source, neural
denoising, real-time engine.)*

## Features

**🎙 Noise cancellation, both directions** — DPDFNet, a full-band 48 kHz deep-
filtering speech model (~28 dB of noise removed, ~98% of voice energy kept):
- **Cancel my noise** — your mic is denoised before Zoom/Teams/Discord/browsers
  hear it, via the virtual **ODE Microphone**
- **Cancel others' noise** — incoming call audio is denoised before you hear
  it, via the virtual **ODE Speaker**

The virtual devices appear only while ODE is running — quit the app and they
vanish from every picker (a crash-safe watchdog in the driver guarantees it).

**📝 On-device meeting transcription** — automatic whenever a call uses an ODE
device. Two switchable engines:
- **Apple** SpeechAnalyzer (macOS 26)
- **Parakeet TDT v3** (NVIDIA, via CoreML on the Neural Engine) — automatic
  language detection across 25 languages, excellent Spanish

**👥 Speaker detection** — remote participants are diarized into
"Speaker 1/2/…" (NVIDIA Sortformer, on-device), on top of the built-in
You/Others separation.

**⚡️ Live meeting view** — watch the transcript grow in real time, and **ask
questions about the meeting while it's still happening** ("what did they say
while I was away?"), answered by Apple's on-device foundation model.

**🧠 Meeting notes** — searchable history with AI summary, key points, action
items, talk-time per speaker, and a persistent Q&A thread per meeting.

**🔊 A/B tester** — record a clip and flip between raw and denoised while it
loops, to hear exactly what ODE removes.

Everything above runs locally: no accounts, no cloud, no bots joining your
calls. See `docs/ROADMAP.md` for what's next (v0.7.0: echo cancellation).

## How it works

```
 Real mic ──► ODE (denoise) ──► "ODE Microphone" ──► call app
 call app ──► "ODE Speaker" ──► ODE (denoise) ──► your real speakers
                     │
                     └─► transcription (Apple / Parakeet) ─► diarization
                            └─► live view · Q&A · summaries (on-device AI)
```

The virtual devices are CoreAudio HAL drivers derived from
[BlackHole](https://github.com/ExistentialAudio/BlackHole), patched for
dynamic visibility. The denoiser is **DPDFNet** via
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx); speech-to-text and
diarization run through [FluidAudio](https://github.com/FluidInference/FluidAudio)
CoreML models on the Apple Neural Engine.

## Install

Grab the notarized installer from
[Releases](https://github.com/jcanizalez/ode/releases) — it installs ODE.app
and both audio drivers, and starts ODE automatically. macOS 14+ (Apple
Silicon); transcription AI features need macOS 26.

## Build from source

Requires macOS 14+, Swift 6 toolchain; full Xcode for the drivers/tests.

```sh
./scripts/fetch-deps.sh      # sherpa-onnx libs + DPDFNet model (~90 MB)
swift build -c release
./scripts/build-app.sh       # dist/ODE.app (signs with your best identity)
./scripts/build-driver.sh    # dist/*.driver (virtual devices)
./scripts/build-pkg.sh       # dist/ODE-x.y.z.pkg installer
```

Releases are automated: pushing a `v*` tag builds, signs, notarizes and
publishes the installer via GitHub Actions.

## CLI

```sh
ode file noisy.wav clean.wav                 # denoise a recording
ode mic 8 raw.wav clean.wav                  # record & compare
ode devices                                  # list CoreAudio devices
ode live --out "ODE Microphone"              # real-time loop, headless
ode transcribe audio.wav --engine parakeet --diarize
ode fakecall --play meeting.wav              # simulate a call end-to-end
```

## Testing

```sh
./scripts/run-tests.sh       # unit tests + coverage
./scripts/e2e-test.sh        # full pipeline test — no real call needed
```

See `docs/TESTING.md` for the fake-call workflow, audio-quality diagnostics
(`engine-stats.log`), and the macOS permission traps to avoid.

## Project layout

```
Package.swift
Sources/
  CSherpa/         C-API bridge to the sherpa-onnx static libraries
  ODEKit/          Engine library: denoise, live loop, devices, transcription,
                   diarization, meeting AI, transcripts
  ode/             CLI front-end
  ODEApp/          Menu-bar app: panel, meetings window, live view, A/B tester
Tests/ODEKitTests/ Unit tests
third_party/sherpa/  Vendored sherpa-onnx libs (via scripts/fetch-deps.sh)
Resources/         DPDFNet model weights (via scripts/fetch-deps.sh)
scripts/
  fetch-deps.sh            Downloads sherpa-onnx libs + DPDFNet model
  build-app.sh             Builds & signs dist/ODE.app
  build-driver.sh          Builds the ODE virtual-audio drivers
  build-pkg.sh             Builds the dist/ODE-x.y.z.pkg installer
  notarize.sh              Notarizes + staples an installer
  run-tests.sh             Unit tests + coverage report
  e2e-test.sh              Full pipeline test without a real call
docs/
  ROADMAP.md               Feature roadmap & competitive landscape
  TESTING.md               How to test everything without joining a call
  VIRTUAL_MIC.md           Virtual-microphone internals & branded build
.github/workflows/         CI (build+test) and Release (tag → notarized pkg)
```

## Licensing & attribution

ODE's own code is released under the MIT License (see `LICENSE`).
Noise suppression uses **DPDFNet** via
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0), which embeds
ONNX Runtime (MIT). Speech-to-text and diarization use
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) running
NVIDIA Parakeet and Sortformer models (CC-BY-4.0). The virtual audio devices
are based on [BlackHole](https://github.com/ExistentialAudio/BlackHole) (MIT).
