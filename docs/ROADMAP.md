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

## Release plan — the next odes

Each release is a themed verse; infra rides along where it fits.

### v0.10.0 — *An Ode to Order* (the split)
- **Slim popover + Settings window** — the menu-bar panel becomes a cockpit
  (status, daily toggles, meetings); everything set-once moves to a
  sidebar-style Settings window (General / Audio / Transcription / Updates /
  About).
- **Noise suppression strength** — High/Medium/Low; lower blends the original
  signal back in for naturalness. Applies live, mid-call.
- **Launch at login** (SMAppService).
- **Auto-updates** (Sparkle + appcast from GitHub releases) — every release
  after this one delivers itself. Invisible-in-screen-share windows, global
  hotkey, Dependabot (built as the withdrawn 0.9.1 "Care").
- **Menu-bar icon fix** — template rendering so it's visible on every bar;
  panel responsiveness fixes.
- Backlog: Liquid-Glass layered .icon via actool (icns fallback kept).

### v0.10.1 — patch (the microphone's mea culpa)
- **Fix dead mic** — echo cancellation (VPIO) has captured pure silence since
  the 0.8.0 engine-lifecycle rework. It now defaults OFF (existing installs
  migrated once) and is labeled experimental until the voice-processing path
  is rebuilt. AirPods/headsets do their own AEC and lose nothing.
- **"System Default" device option** — pickers gain a System Default entry
  (the default): ODE follows the system input/output as it changes, so
  connecting AirPods auto-switches like Krisp. Explicit device pinning stays
  available.
- **Silent-mic detection** — mic path active but capturing zeros for ~10 s →
  orange panel warning naming the likely fix.
- Backlog: **VPIO rearchitecture** — one persistent voice-processing capture
  engine reused across sessions (fresh-engines-per-session conflicts with
  VPIO: dormant instances silence capture, per-session activation storms the
  device stack). Needs a dedicated harness with real-mic assertions.

### v0.11.0 — *An Ode to Tongues* (languages)
- **Live translated captions** — Apple's on-device Translation over the live
  segment stream (es⇄en first). Real-time interpretation without the cloud.
- **Spanish UI localization** — the release about language, in two languages.
- **Map-reduce notes** — chapter-quality summaries for 2-hour meetings.
- Polish: gear moves from the popover footer to the header (beside the
  master toggle); power stays in the footer next to Test.

### v0.12.0 — *An Ode to Presence* (proactive, part 1)
- **Name-mention alerts** — someone says your name → notification with the
  sentence + one-click into the live view (mentions plumbing already exists).
- **Suggested answers** — a question lands on you → the live view drafts a
  reply from meeting context, on-device.

### v0.13.0 — *An Ode to Counsel* (proactive, part 2)
- **Screen context** — ScreenCaptureKit + Apple Vision OCR (fully local) so
  Ask grounds answers in what's on screen, not just what was said.
- **Claude escalation** — explicit "Ask with Claude" for hard questions:
  question + minimal context to the Claude API, per-question, clearly
  badged, never automatic. On-device remains the default.

### v0.14.0 — *An Ode to Names* (knowledge)
- **Named speakers** — voice enrollment via the diarizer's `enrollSpeaker`:
  "Javier:" instead of "Speaker 1:".
- **Cross-meeting Q&A** — ask across the whole transcript store.
- **Action-item export** — owners' tasks to Reminders / Markdown clipboard.
- **Microsoft Graph calendar connector** (opt-in) for Outlook-only setups.

### v0.15.0 — *An Ode to Craft* (the voice itself)
- **Studio Voice** — pro-mic DSP chain (high-pass, warmth, presence,
  compressor, limiter). Most of "podcast voice" is EQ + dynamics, not AI.
- **Call recording** — optionally keep denoised audio next to transcripts.
- **Speaking analytics** — fillers/WPM/monologues from stored transcripts.

### v1.0.0 — *An Ode to Voice* (the milestone)
Everything above proven in daily use, plus whichever research item matured:
- **Background voice cancellation** — suppress other people's voices near
  you (personalized speech extraction; ambitious).
- **Accent conversion / speech-to-speech translation** — revisit as
  ANE-native generative speech models mature.

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
