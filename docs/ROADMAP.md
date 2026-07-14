# ODE Roadmap

Where ODE stands against the commercial field (Krisp, NVIDIA Broadcast,
platform built-ins) and what comes next. Snapshot: July 2026.

ODE's differentiator: **everything runs on-device.** Krisp does noise
cancellation locally but its meeting assistant (transcription, summaries,
translation) is cloud-based. ODE does the whole stack — denoise, transcribe,
diarize, summarize, Q&A — without audio or text ever leaving the Mac.

## Shipped

- Noise cancellation, both directions (DPDFNet 48 kHz full-band):
  "Cancel my noise" (mic path) and "Cancel others' noise" (speaker path)
- Virtual devices ("ODE Microphone" / "ODE Speaker") with dynamic hiding —
  visible only while the app runs, watchdog-hidden if it crashes
- On-device meeting transcription, two engines: Apple SpeechAnalyzer and
  NVIDIA Parakeet TDT v3 (auto language ID, strong Spanish), switchable
- Speaker diarization (Sortformer): remote participants become "Speaker 1/2/…"
- Live meeting view: growing transcript + real-time Q&A about the meeting so
  far (Apple Foundation Models); live Q&A persists with the saved transcript
- Meeting notes: summary, key points, action items, talk-time, saved Q&A
- Robustness: device hot-plug recovery, engine auto-restart, jitter-buffered
  audio pipeline with per-session diagnostics
- Test infrastructure without real calls (`ode fakecall`, `scripts/e2e-test.sh`,
  engine-stats log) — see `docs/TESTING.md`
- Developer ID signed, notarized, one-command releases via GitHub Actions

## Next: v0.7.0 — Echo cancellation

Without headphones, the mic picks up whatever the speakers play: the remote
side hears themselves back, and the "You" transcript absorbs other people's
words (observed directly in E2E testing). Fix: Apple's voice-processing I/O
(AEC against the system output) on the mic path, with ducking disabled so the
speaker path is unaffected. Toggleable, on by default.

## Backlog (rough priority)

1. **Calendar-aware meetings** — title transcripts from the EventKit event
   ("Sprint Planning", attendees) instead of "11:09 AM Meeting"; fill
   `Transcript.sourceApp` from the app using the virtual device.
2. **Speaking analytics** — filler words ("este…", "o sea", "um"), pace (WPM),
   interruptions; computed from transcripts we already store.
3. **Live translated captions** — Apple's on-device Translation framework over
   the live segment stream (es⇄en first). The on-device answer to Krisp's
   cloud AI Live Interpreter.
4. **Named speakers** — voice enrollment via Sortformer's `enrollSpeaker`
   (already in our FluidAudio dependency): "Javier:" instead of "Speaker 1:".
5. **Studio Voice** — pro-mic DSP chain on the mic path (high-pass, warmth
   shelf, presence boost, compressor, limiter via Apple AUs). Most of the
   perceived "podcast voice" difference is EQ + dynamics, not AI.
6. **Background voice cancellation** — suppress *other people's voices* near
   you (Krisp's flagship). Needs personalized speech extraction with a voice
   enrollment; ambitious, model-dependent, treat as an experiment.
7. **Accent conversion / speech-to-speech translation** — Krisp's 2026
   headliners; real-time generative speech is not yet practical on-device.
   Revisit as ANE-native speech models mature.

## Competitive reference (July 2026)

| Capability | Krisp | ODE |
|---|---|---|
| Noise cancellation | ✅ local | ✅ local |
| Echo cancellation | ✅ | v0.7.0 |
| Background voice cancellation | ✅ | backlog |
| Transcription | ✅ cloud | ✅ **on-device** |
| Summaries / action items | ✅ cloud | ✅ **on-device** |
| Live meeting Q&A | — | ✅ on-device |
| Diarization | ✅ | ✅ on-device |
| Accent conversion | ✅ cloud | not planned (yet) |
| Live translation | ✅ cloud (61 langs) | backlog (on-device) |
