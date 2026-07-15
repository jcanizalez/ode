# ODE Roadmap

Where ODE stands and what comes next. Snapshot: July 2026.

ODE's differentiator: **everything runs on-device.** Commercial voice tools
typically do noise removal locally but send meetings to the cloud for
transcription, summaries, and translation. ODE does the whole stack —
denoise, transcribe, diarize, summarize, Q&A — without audio or text ever
leaving the Mac.

## Shipped

- **Panel redesign + identity** (v0.9.0) — status header, disclosure rows
  with hint rings, live-aware Meetings row; "Clearing Wave" app icon and
  menu-bar icon rendered from code; device pickers filtered to real hardware.
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

1. **Live translated captions** (v0.10.0) — Apple's on-device Translation
   framework over the live segment stream (es⇄en first). Real-time
   interpretation without the cloud.
2. **Named speakers** — voice enrollment via the diarizer's `enrollSpeaker`
   (already in our FluidAudio dependency): "Javier:" instead of "Speaker 1:".
3. **Studio Voice** — pro-mic DSP chain on the mic path (high-pass, warmth
   shelf, presence boost, compressor, limiter via Apple AUs). Most of the
   perceived "podcast voice" difference is EQ + dynamics, not AI.
4. **Liquid-Glass layered .icon** — hand-authored layers compiled via actool
   (Assets.car + CFBundleIconName), keeping the .icns fallback.
5. **Auto-updates** — Sparkle fed by an appcast generated from our GitHub
   releases; ends the manual pkg-download loop.
6. **Spanish UI localization** — the app answers in Spanish; its UI should too.
7. **Cross-meeting Q&A** — ask across the whole transcript store ("what did
   we decide about mTLS, ever?"), not just one meeting.
8. **Action-item export** — owners' tasks to Reminders / Markdown clipboard.
9. **Microsoft Graph calendar connector** — opt-in titles/attendees when
   Outlook isn't synced to macOS Calendar (OAuth; metadata only).
10. **Speaking analytics** — fillers/WPM/monologues from stored transcripts.
11. **Call recording** — optionally keep denoised audio next to transcripts.
12. **Map-reduce notes** — chapter-quality summaries for 2-hour meetings.
13. **Global hotkey** — toggle noise cancellation without opening the panel.

## Proactive ODE (Glass-inspired)

Today ODE listens and remembers; the next leap is *acting in the moment* —
inspired by Glass/CheatingDaddy-style assistants, but with ODE's stance:
on-device by default, cloud only by explicit opt-in.

- **Name-mention alerts** — we already detect "Javier" in live segments;
  surface a notification with the last sentence and one-click jump into the
  live view. (Cheapest win — the plumbing exists.)
- **Suggested answers** — when a question is directed at you, draft a reply
  from the meeting context using the on-device model, shown in the live view.
- **Screen context** — ScreenCaptureKit + Apple Vision OCR (all local) so
  "Ask" can ground answers in what's on screen, not just what was said.
- **Claude escalation** — an opt-in "advanced answers" mode that sends the
  question + minimal context to the Claude API (or another provider) for
  deep reasoning; clearly indicated, per-question, never automatic.
- **Invisible windows** — NSWindow.sharingType = .none so ODE's panels never
  appear in screen shares or recordings (one-liner, do it early).
6. **Background voice cancellation** — suppress *other people's voices* near
   you while keeping yours. Needs personalized speech extraction with a voice
   enrollment; ambitious, model-dependent, treat as an experiment.
7. **Accent conversion / speech-to-speech translation** — real-time
   generative speech is not yet practical on-device. Revisit as ANE-native
   speech models mature.
