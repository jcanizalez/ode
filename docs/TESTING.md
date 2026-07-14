# Testing ODE

How to test ODE's full pipeline — denoising, virtual devices, transcription,
diarization, live view, transcript saving — **without joining a real call**,
and how to diagnose audio-quality problems with hard numbers instead of ears.

All of this was built (and battle-tested) on 2026-07-14, when a single fake
call caught three real bugs: a main-thread freeze, a permission deadlock, and
a 14% sample loss that caused periodic audio dropouts.

---

## 1. Quick reference

| I want to… | Run |
|---|---|
| Test the whole pipeline end-to-end | `./scripts/e2e-test.sh` |
| Exercise the pipeline with my own audio | `.build/debug/ode fakecall --play meeting.wav` |
| Check audio quality after any call (real or fake) | `cat ~/Library/Application\ Support/ODE/engine-stats.log` |
| Compare transcription engines on a recording | `.build/debug/ode transcribe file.wav --engine apple\|parakeet [--diarize]` |
| Run the unit tests + coverage | `./scripts/run-tests.sh` |

---

## 2. The fake call (`ode fakecall`)

The pipeline only activates when a real app uses the ODE virtual devices.
`fakecall` **impersonates a conferencing app**: it opens an input client on
"ODE Microphone" (what Zoom would read) and plays a file into "ODE Speaker"
(the incoming call audio). Both denoise paths start, transcription and
diarization run, the live view populates, and the transcript saves at the end
— exactly like a real meeting.

```sh
swift build
.build/debug/ode fakecall --play /tmp/es_meeting.wav \
    [--record /tmp/mic_out.wav]   # save what a call app would hear from you
    [--seconds 20]                # default: file duration + 2 s
```

It reports:
- **peak level** of the mic-path output — `0.0000` + nonzero exit means the
  mic path produced silence (see §5, almost always a permission problem)
- **glitch count** — abrupt sample discontinuities (hard pops/clicks)

Requires ODE.app to be **running** (the devices are hidden otherwise — if
`fakecall` says the devices are missing, that's itself a test failure).

## 3. The E2E script (`scripts/e2e-test.sh`)

One command, no arguments needed:

```sh
./scripts/e2e-test.sh [optional-audio.wav]
```

What it does:
1. Synthesizes a two-speaker Spanish meeting with `say` (or uses your file)
2. Quits ODE, enables transcription via `defaults write com.ode.app
   ode.transcribeEnabled -bool true`, relaunches `dist/ODE.app`
   (override with `ODE_APP=/Applications/ODE.app`)
3. Runs the fake call (you'll hear the meeting through your speakers —
   that's the speaker path denoising to your real output)
4. Waits for the transcript to finalize and **fails if none was saved**;
   prints the segments (with `Speaker 1/2` labels when Detect speakers is on)

Pass = `✓ E2E PASSED` with a plausible transcript.

## 4. Audio-quality numbers (`engine-stats.log`)

Every engine session (each path of each call) appends one line to
`~/Library/Application Support/ODE/engine-stats.log`:

```
2026-07-14T17:29:49Z [speaker] wrote=978240 played=968704 underruns=0 skips=0 inPeak=0.6580 maxWriteGap=117ms slowWrites=0
```

How to read it:

| Field | Meaning | Healthy |
|---|---|---|
| `wrote` / `played` | samples produced / consumed (48 kHz) | within ~2% of each other, and `wrote ≈ 48000 × call seconds` |
| `underruns` | buffer ran dry → **audible dropout** ("ploc") | **0** (1–2 per long call tolerable) |
| `skips` | backlog was dropped to cap latency → one audible skip | 0 |
| `inPeak` | loudest captured input sample | > 0.01 with speech; **0.0000 = OS delivered silence (mic permission denied)** |
| `maxWriteGap` | longest pause between buffer writes | < 200 ms (the jitter cushion size) |

Diagnosis patterns (all observed for real):
- `underruns` high + `wrote` ~10–15% below `48000 × seconds` → **sample-rate
  conversion losing audio** (the per-buffer-converter bug, fixed in 0.5.4)
- `underruns` high + `maxWriteGap` > 200 ms → CPU starvation or stalls
- `inPeak=0.0000` on `[mic]` → TCC permission, not a pipeline bug
- session lines with `wrote=0` → the engine started but never pumped
  (historically: blocked on a permission prompt)

## 5. ⚠️ Permission (TCC) traps — read before trusting any measurement

These mimic real bugs and wasted hours before being identified:

1. **Shell mic captures are silently zeroed.** Any process reading a
   microphone — *including the virtual ODE Microphone* — from a terminal
   without mic permission records pure silence, no error. Grant your terminal
   app mic access (System Settings → Privacy & Security → Microphone) or
   `fakecall`'s mic-path checks are meaningless.
2. **Launch the app with `open`, never by executing the binary directly** —
   a directly-executed `ODE.app/Contents/MacOS/ODE` inherits the *terminal's*
   TCC identity and gets denied.
3. **Every rebuild re-prompts** (ad-hoc signing = new app identity each
   build). A missed prompt used to block the engine forever; since 0.5.3 the
   prompt fires at launch and engines run off the main thread, but you still
   must click Allow after installing a new build.
4. A recorded **Deny is permanent and silent**. Reset with:
   `tccutil reset Microphone com.ode.app`
5. `log show` is unreliable for ODE's NSLogs on some setups — that's why
   `engine-stats.log` exists. For full app logs during a debug session, the
   unified log may work on your machine; otherwise rely on the stats file.

## 6. Transcription / diarization on files

```sh
.build/debug/ode transcribe grabacion.wav --engine parakeet --diarize
.build/debug/ode transcribe grabacion.wav --engine apple
```

Prints timestamped segments (with `Speaker N:` labels under `--diarize`).
Useful for A/B-ing engines on identical audio. First Parakeet/diarizer runs
download models (~470 MB / ~230 MB) to
`~/Library/Application Support/FluidAudio/Models/`.

Generate multi-speaker Spanish test audio (the e2e script automates this):

```sh
say -v "Eddy (Spanish (Mexico))" -o a.aiff "Buenos días a todos."
say -v "Flo (Spanish (Mexico))"  -o b.aiff "Gracias, empecemos."
afconvert -f WAVE -d LEI16@16000 -c 1 a.aiff a.wav   # etc., then concatenate
```

## 7. Unit tests

```sh
./scripts/run-tests.sh        # swift test + coverage table
```

Uses full Xcode explicitly (`xcode-select` often points at the Command Line
Tools, which lack XCTest). 68 tests, ~53% line coverage of `Sources/ODEKit`,
including the ring buffer's jitter behavior and the Parakeet segment
reconciliation.

## 8. Suggested checklist for a new build

1. `./scripts/run-tests.sh` → all green
2. `./scripts/build-app.sh && open dist/ODE.app` → click Allow if prompted
3. `./scripts/e2e-test.sh` → `✓ E2E PASSED`, listen for dropouts during
   playback
4. `tail -2 ~/Library/Application\ Support/ODE/engine-stats.log` →
   `underruns=0`, `inPeak` > 0 on both paths
5. Quit ODE from the panel → "ODE Microphone/Speaker" disappear from
   System Settings → Sound within a second (hide-on-quit works)
6. Optionally: one real call for the human ear test
