# ODE Roadmap

Where ODE stands and what comes next. Snapshot: July 2026.

ODE's differentiator: **everything runs on-device.** Commercial voice tools
typically do noise removal locally but send meetings to the cloud for
transcription, summaries, and translation. ODE does the whole stack —
denoise, transcribe, diarize, summarize, Q&A — without audio or text ever
leaving the Mac.

## Shipped

- **Meeting intelligence** (v0.8.0) — auto-generated notes when a meeting
  ends: timestamped chapters, decisions, open questions, action items with
  owners, mentions-of-you, speaker rename, recap email. Calendar-aware
  titles (EventKit) with AI fallback in the meeting's language; source-app
  tagging. The AI knows who "You" is from the account name.
- Noise cancellation, both directions (DPDFNet 48 kHz full-band):
  "Cancel my noise" (mic path) and "Cancel others' noise" (speaker path)
- **Echo cancellation** (v0.7.0) — take calls on speakers without the remote
  side hearing themselves or speaker audio bleeding into transcripts
- Virtual devices ("ODE Microphone" / "ODE Speaker") with dynamic hiding —
  visible only while the app runs, watchdog-hidden if it crashes
- On-device meeting transcription, two engines: Apple SpeechAnalyzer and
  Parakeet TDT v3 (auto language ID, strong Spanish), switchable
- Speaker diarization: remote participants become "Speaker 1/2/…"
- Live meeting view: growing transcript + real-time Q&A about the meeting so
  far (Apple Foundation Models); live Q&A persists with the saved transcript
- Meeting notes: summary, key points, action items, talk-time, saved Q&A
- Robustness: device hot-plug recovery, engine auto-restart, jitter-buffered
  audio pipeline with per-session diagnostics
- Test infrastructure without real calls (`ode fakecall`, `scripts/e2e-test.sh`,
  engine-stats log) — see `docs/TESTING.md`
- Developer ID signed, notarized, one-command releases via GitHub Actions

## Backlog (rough priority)

1. **Panel redesign** (v0.9.0) — refined cards + disclosure ("Advanced"
   rows), status line back in the header, echo-cancellation moved to the
   mic card's context; scales as settings grow.
2. **Live translated captions** — Apple's on-device Translation framework over
   the live segment stream (es⇄en first). Real-time interpretation without
   the cloud.
4. **Named speakers** — voice enrollment via the diarizer's `enrollSpeaker`
   (already in our FluidAudio dependency): "Javier:" instead of "Speaker 1:".
5. **Studio Voice** — pro-mic DSP chain on the mic path (high-pass, warmth
   shelf, presence boost, compressor, limiter via Apple AUs). Most of the
   perceived "podcast voice" difference is EQ + dynamics, not AI.
6. **Background voice cancellation** — suppress *other people's voices* near
   you while keeping yours. Needs personalized speech extraction with a voice
   enrollment; ambitious, model-dependent, treat as an experiment.
7. **Accent conversion / speech-to-speech translation** — real-time
   generative speech is not yet practical on-device. Revisit as ANE-native
   speech models mature.
