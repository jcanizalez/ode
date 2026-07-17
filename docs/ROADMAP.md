# ODE Roadmap

Where ODE stands and what comes next. Snapshot: July 2026.

ODE's differentiator: **everything runs on-device.** Commercial voice tools
typically do noise removal locally but send meetings to the cloud for
transcription, summaries, and translation. ODE does the whole stack —
denoise, transcribe, diarize, summarize, translate, Q&A — without audio or
text ever leaving the Mac.

## Shipped

- **An Ode to Craft** (v0.12.0) — Studio Voice: a real broadcast chain on the
  mic path (steep high-pass, mud cut, warmth/presence/air EQ, loudness AGC,
  room-taming downward expander, 3-band compressor with integrated de-esser,
  tape saturation, peak limiter — zero latency, on-device), with an A/B
  switch in the test window; call recording (both sides mixed into one AAC
  next to the transcript, playable from the Meetings window); speaking
  analytics tab (pace, talk share, fillers in EN/ES, longest monologues
  with jump links).
- **An Ode to Tongues** (v0.11.0) — live translated captions in every Apple
  on-device language (~20, queried at runtime; source language detected from
  the transcript; retro-translates saved meetings); Spanish UI (String
  Catalog, permission prompts included); map-reduce notes for long meetings;
  echo cancellation rebuilt on a persistent VoiceProcessingIO unit, verified
  by a real-microphone harness (`scripts/mic-e2e.sh`).
- **An Ode to Be Heard** (v0.10.1) — dead-mic fix (echo cancellation off by
  default until rebuilt), "System Default" device mode that follows the
  system as AirPods connect, silent-mic panel warning, self-healing engine watchdog,
  meeting-end grace so device switches don't split transcripts.
- **An Ode to Order** (v0.10.0) — slim popover + sidebar Settings window;
  noise suppression strength (live dry/wet blend); launch at login; Sparkle
  auto-updates with signed appcast; hide-from-screen-share windows; ⌃⌥⌘O
  hotkey; template menu-bar icon (visible on every bar); Dependabot.
- **Panel redesign + identity** (v0.9.0) — status header, hint rings,
  live-aware Meetings row; "Clearing Wave" app icon rendered from code;
  device pickers filtered to real hardware.
- **Meeting intelligence** (v0.8.0) — auto-generated notes when a meeting
  ends: timestamped chapters, decisions, open questions, action items with
  owners, mentions-of-you, speaker rename, recap email. Calendar-aware
  titles (EventKit) with AI fallback in the meeting's language; source-app
  tagging. The AI knows who "You" is from the account name.
- **Echo cancellation** (v0.7.0) — take calls on speakers without the remote
  side hearing themselves or speaker audio bleeding into transcripts.
- Noise cancellation, both directions (DPDFNet 48 kHz full-band):
  "Cancel my noise" (mic path) and "Cancel others' noise" (speaker path).
- Virtual devices ("ODE Microphone" / "ODE Speaker") with dynamic hiding —
  visible only while the app runs, watchdog-hidden if it crashes.
- On-device meeting transcription, two engines: Apple SpeechAnalyzer and
  Parakeet TDT v3 (auto language ID, strong Spanish), switchable.
- Speaker diarization: remote participants become "Speaker 1/2/…".
- Live meeting view: growing transcript + real-time Q&A about the meeting so
  far (Apple Foundation Models); live Q&A persists with the saved transcript.
- Robustness: device hot-plug recovery, engine auto-restart, jitter-buffered
  audio pipeline with per-session diagnostics.
- Test infrastructure without real calls (`ode fakecall`,
  `scripts/e2e-test.sh`, `scripts/mic-e2e.sh`, engine-stats log) — see
  `docs/TESTING.md`.
- Developer ID signed, notarized, one-command releases via GitHub Actions;
  self-updating via Sparkle.

## Release plan — the next odes

Each release is a themed verse; infra rides along where it fits. The
proactive features keep ODE's stance: on-device by default, cloud only by
explicit per-question opt-in.

### v0.13.0 — *An Ode to Presence* (proactive, part 1 — next)
- **Name-mention alerts** — someone says your name → notification with the
  sentence + one-click into the live view (mentions plumbing already exists).
- **Suggested answers** — a question lands on you → the live view drafts a
  reply from meeting context, on-device.

### v0.14.0 — *An Ode to Counsel* (proactive, part 2)
- **Screen context** — ScreenCaptureKit + Apple Vision OCR (fully local) so
  Ask grounds answers in what's on screen, not just what was said.
- **Claude escalation** — explicit "Ask with Claude" for hard questions:
  question + minimal context to the Claude API, per-question, clearly
  badged, never automatic. On-device remains the default.

### v0.15.0 — *An Ode to Names* (knowledge)
- **Named speakers** — voice enrollment via the diarizer's `enrollSpeaker`:
  "Javier:" instead of "Speaker 1:".
- **Cross-meeting Q&A** — ask across the whole transcript store.
- **Action-item export** — owners' tasks to Reminders / Markdown clipboard.
- **Microsoft Graph calendar connector** (opt-in) for Outlook-only setups.

### v1.0.0 — *An Ode to Voice* (the milestone)
Everything above proven in daily use, plus whichever research item matured:
- **Background voice cancellation** — suppress other people's voices near
  you (personalized speech extraction; ambitious).
- **Accent conversion / speech-to-speech translation** — revisit as
  ANE-native generative speech models mature.

## Backlog (rides along when it fits)

- **Dereverberation model spike** — the expander dries the room *between*
  words; reverb *during* speech needs a model. Evaluate the streaming
  GTCRN enhancement already in the vendored sherpa-onnx and DeepFilterNet3
  against the current denoiser on reverberant speech.
- **"Enhance recording" (offline)** — run a heavier restoration model over
  saved call recordings, where real-time doesn't constrain quality.
- **Studio Voice intensity setting** — Low/Medium/High preset on the
  broadcast chain if one fixed character doesn't fit every voice.
- **Flip echo cancellation default-on** and drop the EXPERIMENTAL badge once
  `scripts/mic-e2e.sh` accumulates ~20 consecutive passes across device
  configurations (3 so far).
- **More UI languages** — the String Catalog makes each one a translation
  pass, not a code change.
- **Liquid-Glass layered .icon** via actool (icns fallback kept).
