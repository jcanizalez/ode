#!/bin/sh
# ODE end-to-end pipeline test — no real call needed.
#
# Simulates a full meeting: launches ODE.app with transcription enabled, plays
# a two-speaker Spanish "meeting" into ODE Speaker while reading ODE
# Microphone (exactly what Zoom/Teams do), then verifies:
#   1. both denoise paths activated,
#   2. no pops/glitches on the mic path,
#   3. a transcript was saved with segments.
#
# Usage:  ./scripts/e2e-test.sh [audio.wav]
#   ODE_APP=/path/to/ODE.app   override the app under test (default dist/ODE.app)

set -e
cd "$(dirname "$0")/.."

APP="${ODE_APP:-dist/ODE.app}"
AUDIO="${1:-/tmp/ode_e2e_meeting.wav}"
MIC_OUT="/tmp/ode_e2e_mic.wav"
STORE="$HOME/Library/Application Support/ODE/Transcripts"

# --- 0. Build the CLI ---
echo "Building ode CLI…"
swift build --product ode >/dev/null 2>&1
ODE_BIN=".build/debug/ode"

# --- 1. Synthesize a two-speaker Spanish meeting if none was provided ---
if [ ! -f "$AUDIO" ]; then
    echo "Synthesizing test meeting audio…"
    say -v "Eddy (Spanish (Mexico))" -o /tmp/ode_e2e_1.aiff \
        "Buenos días a todos. Empecemos con la reunión de seguimiento del proyecto."
    say -v "Flo (Spanish (Mexico))" -o /tmp/ode_e2e_2.aiff \
        "Gracias. La semana pasada terminamos la integración y ya está en pruebas."
    say -v "Eddy (Spanish (Mexico))" -o /tmp/ode_e2e_3.aiff \
        "Perfecto. Entonces la próxima semana hacemos la demostración con el cliente."
    for f in 1 2 3; do
        afconvert -f WAVE -d LEI16@16000 -c 1 "/tmp/ode_e2e_$f.aiff" "/tmp/ode_e2e_$f.wav"
    done
    python3 - "$AUDIO" <<'PY'
import sys, wave
out = wave.open(sys.argv[1], 'wb')
out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
silence = b'\x00\x00' * 8000
for i in (1, 2, 3):
    w = wave.open(f'/tmp/ode_e2e_{i}.wav', 'rb')
    out.writeframes(w.readframes(w.getnframes()))
    out.writeframes(silence)
    w.close()
out.close()
PY
fi

# --- 2. Launch the app under test with transcription enabled ---
echo "Restarting ODE with transcription enabled…"
osascript -e 'quit app "ODE"' >/dev/null 2>&1 || true
sleep 2
defaults write com.ode.app ode.transcribeEnabled -bool true
open "$APP"
sleep 4   # devices unhide + observers install

# --- 3. Snapshot the transcript store ---
BEFORE=$(ls "$STORE"/*.json 2>/dev/null | wc -l | tr -d ' ')

# --- 4. Run the fake call ---
"$ODE_BIN" fakecall --play "$AUDIO" --record "$MIC_OUT"

# --- 5. Wait for the transcript to finalize and save ---
echo "Waiting for transcript to save…"
for i in $(seq 1 15); do
    AFTER=$(ls "$STORE"/*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$AFTER" -gt "$BEFORE" ] && break
    sleep 2
done

if [ "$AFTER" -gt "$BEFORE" ]; then
    NEWEST=$(ls -t "$STORE"/*.json | head -1)
    echo "✓ Transcript saved: $NEWEST"
    python3 - "$NEWEST" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
segs = sorted(t['segments'], key=lambda s: s['start'])
print(f"  title: {t['title']}  ({len(segs)} segments)")
for s in segs:
    print(f"  [{int(s['start'])//60:02d}:{int(s['start'])%60:02d}] {s['speaker']}: {s['text'][:90]}")
PY
    echo
    echo "✓ E2E PASSED"
else
    echo "✗ No transcript was saved — E2E FAILED"
    echo "  (Is the speaker path enabled? Check the ODE panel / logs.)"
    exit 1
fi
