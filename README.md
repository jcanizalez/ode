# ODE — an ode to your voice

**ODE** is named after the *ode* — a lyric poem written in celebration of
something. This one is a celebration of **your voice**: an open-source,
real-time AI meeting companion for macOS. It removes background noise in both
directions, transcribes, translates and summarizes your meetings, and answers
questions about them — **entirely on-device**. Nothing you say ever leaves
your Mac.

*(ODE also happens to stand for **Open Denoise Engine** — open source, neural
denoising, real-time engine.)*

## Features

**🎙 Noise cancellation, both directions** — DPDFNet, a full-band 48 kHz deep-
filtering speech model (~28 dB of noise removed, ~98% of voice energy kept):
- **Cancel my noise** — your mic is denoised before Zoom/Teams/Discord/browsers
  hear it, via the virtual **ODE Microphone**
- **Cancel others' noise** — incoming call audio is denoised before you hear
  it, via the virtual **ODE Speaker**
- **Strength** — blend the denoised signal back toward the original, live

The virtual devices appear only while ODE is running — quit the app and they
vanish from every picker (a crash-safe watchdog in the driver guarantees it).

**🔇 Echo cancellation** — take calls on speakers without the far side hearing
themselves, and without speaker audio bleeding into your transcript.

**🎚 Studio Voice** — an optional broadcast chain on the mic path: steep
high-pass, mud cut, warmth/presence/air EQ, loudness levelling, a room-taming
expander, 3-band compression with de-essing, saturation and a peak limiter.
Zero latency, on-device.

**📝 On-device meeting transcription** — automatic whenever a call uses an ODE
device. Two switchable engines:
- **Apple** SpeechAnalyzer (macOS 26)
- **Parakeet TDT v3** (NVIDIA, via CoreML on the Neural Engine) — automatic
  language detection across 25 languages, excellent Spanish

**👥 Speakers, by name** — remote participants are diarized into
"Speaker 1/2/…" (NVIDIA Sortformer, on-device), on top of the built-in
You/Others separation. Name one and ODE keeps a few seconds of their voice,
so later meetings label them by name on their own. The samples are seconds
long, stay on your Mac, and can be reviewed or forgotten in Settings.

**🌍 Live translation** — captions translated as the meeting runs, in every
on-device Apple language (~20, detected from the transcript); saved meetings
can be retranslated after the fact. The app itself speaks English and Spanish.

**⚡️ Live meeting view** — watch the transcript grow in real time, and **ask
questions about the meeting while it's still happening** ("what did they say
while I was away?"), answered by Apple's on-device foundation model.

**🧠 Meeting notes** — searchable history with an AI summary, key points,
timestamped chapters, decisions, open questions, action items with owners,
and mentions of you. Titles come from your calendar when there's an event,
otherwise from the content. Draft a recap email in a click, or ask anything
about a meeting and keep the answers alongside it.

**📊 Speaking analytics** — talk share, pace, filler words (EN/ES) and longest
monologues, with jump links into the transcript.

**⏺ Call recording** — optionally keep each meeting's audio, both sides mixed
into one file next to its transcript, playable from the Meetings window.

**🔊 A/B tester** — record a clip and flip between raw and denoised while it
loops, to hear exactly what ODE removes.

**⚙️ Lives quietly on your Mac** — menu-bar only, launch at login, a ⌃⌥⌘O
hotkey, hidden from screen sharing, signed and notarized with automatic
updates, and a one-click diagnostics export when something needs explaining.

Everything above runs locally: no accounts, no cloud, no bots joining your
calls. See `docs/ROADMAP.md` for what's next.

## How it works

```
 Real mic ──► ODE (denoise · echo cancel · Studio Voice) ──► "ODE Microphone" ──► call app
 call app ──► "ODE Speaker" ──► ODE (denoise) ──► your real speakers
                     │
                     └─► transcription (Apple / Parakeet) ─► diarization
                            └─► live view · translation · Q&A · notes (on-device AI)
```

The virtual devices are CoreAudio HAL drivers derived from
[BlackHole](https://github.com/ExistentialAudio/BlackHole), patched for
dynamic visibility. The denoiser is **DPDFNet** via
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx); speech-to-text and
diarization run through [FluidAudio](https://github.com/FluidInference/FluidAudio)
CoreML models on the Apple Neural Engine. Capture sits directly on CoreAudio
(AUHAL), pinned to the device you picked at the format its hardware speaks.

## Install

Grab the notarized installer from
[Releases](https://github.com/jcanizalez/ode/releases) — it installs ODE.app
and both audio drivers, and starts ODE automatically. macOS 14+ (Apple
Silicon); transcription, translation and AI features need macOS 26 with
Apple Intelligence enabled.

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
publishes the installer via GitHub Actions, then updates the update feed.

## CLI

```sh
ode file noisy.wav clean.wav                 # denoise a recording
ode mic 8 raw.wav clean.wav                  # record & compare
ode devices                                  # list CoreAudio devices
ode live --out "ODE Microphone"              # real-time loop, headless
ode transcribe audio.wav --engine parakeet --diarize
ode fakecall --play meeting.wav              # simulate a call end-to-end
```

Debug helpers used by the test harnesses:

```sh
ode micstatus                                # is the mic held right now?
ode watch "MacBook Pro Microphone"           # observe a device's input usage
ode summarize meeting.json                   # run meeting AI over a transcript
```

## Testing

```sh
./scripts/run-tests.sh       # unit tests + coverage
./scripts/e2e-test.sh        # full pipeline test — no real call needed
./scripts/mic-e2e.sh         # real-microphone harness (echo cancellation)
```

See `docs/TESTING.md` for the fake-call workflow, audio-quality diagnostics
(`engine-stats.log`), and the macOS permission traps to avoid.

## Project layout

```
Package.swift
Sources/
  CSherpa/         C-API bridge to the sherpa-onnx static libraries
  CObjCCatch/      Catches the Objective-C exceptions AVFAudio raises
  ODEKit/          Engine library: denoise, capture, live loop, devices,
                   transcription, diarization, voices, meeting AI, transcripts
  ode/             CLI front-end
  ODEApp/          Menu-bar app: panel, meetings window, live view, A/B tester
Tests/ODEKitTests/ Unit tests
third_party/sherpa/  Vendored sherpa-onnx libs (via scripts/fetch-deps.sh)
Resources/         DPDFNet model weights (via scripts/fetch-deps.sh)
scripts/
  fetch-deps.sh            Downloads sherpa-onnx libs + DPDFNet model
  build-app.sh             Builds & signs dist/ODE.app
  build-driver.sh          Builds the ODE virtual-audio drivers
  ode-driver-visibility.patch  BlackHole patch: dynamic device visibility
  build-pkg.sh             Builds the dist/ODE-x.y.z.pkg installer
  install-virtual-mic.sh   Installs a driver locally without the pkg
  make-icon.swift          Renders the app icon from code
  notarize.sh              Notarizes + staples an installer
  update-appcast.py        Adds a release to the Sparkle update feed
  seed-fake-transcripts.py Generates sample meetings for UI work
  run-tests.sh             Unit tests + coverage report
  e2e-test.sh              Full pipeline test without a real call
  mic-e2e.sh               Real-microphone harness for echo cancellation
docs/
  ROADMAP.md               Feature roadmap
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
Automatic updates use [Sparkle](https://github.com/sparkle-project/Sparkle)
(MIT), embedded in the app bundle.
