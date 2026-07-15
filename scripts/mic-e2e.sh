#!/bin/bash
# Real-microphone end-to-end test for the mic path — BOTH echo-cancellation
# modes, TWO sessions each (session 2 is the historical VPIO failure).
#
# How it works: launches the APP (dist/ODE.app — capture runs in its TCC
# context; shell-side recordings are TCC-silenced, so all assertions read the
# app's own engine-stats.log inPeak). Synthesized speech plays through the
# real speakers; the real mic hears it; the app's mic path must register it.
#
# Precondition: dist/ODE.app built (scripts/build-app.sh) and granted
# Microphone permission once. Run from the repo root.
set -u

STATS="$HOME/Library/Application Support/ODE/engine-stats.log"
CLI=".build/release/ode"
SPEECH=/tmp/mic-e2e-speech
FAILURES=0

say -o "$SPEECH.aiff" "Testing the ODE microphone path, one two three, testing testing, la la la" 2>/dev/null
afconvert -f WAVE -d LEI16@48000 "$SPEECH.aiff" "$SPEECH.wav"
[ -x "$CLI" ] || { echo "build the CLI first: swift build -c release --product ode"; exit 2; }
osascript -e 'set volume output volume 60' 2>/dev/null || true

# grep -c prints the count even when it's 0 (exit code 1) — never append a
# fallback echo or the caller gets two lines.
mic_lines() { grep -c "\[mic\]" "$STATS" 2>/dev/null | head -1; }

newest_inpeak_after() {  # $1 = line count before the session
    local before=$1
    local total
    total=$(mic_lines)
    if [ "$total" -le "$before" ]; then echo "none"; return; fi
    grep "\[mic\]" "$STATS" | tail -n $((total - before)) \
        | sed -n 's/.*inPeak=\([0-9.]*\).*/\1/p' | sort -g | tail -1
}

for EC in 0 1; do
    echo "── echo cancellation: $([ "$EC" = 1 ] && echo ON || echo off) ──"
    osascript -e 'quit app "ODE"' 2>/dev/null; pkill -x ODE 2>/dev/null; sleep 2
    defaults write com.ode.app ode.echoCancel -bool "$([ "$EC" = 1 ] && echo true || echo false)"
    defaults write com.ode.app "ode.echoCancelForcedOff.0101" -bool true  # block the migration
    defaults write com.ode.app ode.micEnabled -bool true
    open dist/ODE.app
    sleep 8  # app boot + (EC on) VPIO prepare storm settles off-call

    for SESSION in 1 2; do
        BEFORE=$(mic_lines)
        ( sleep 3; afplay "$SPEECH.wav"; afplay "$SPEECH.wav" ) &
        "$CLI" fakecall --play "$SPEECH.wav" --record /tmp/mic-e2e-out.wav --seconds 14 >/dev/null 2>&1
        wait
        # Session stats flush when the mic engine stops (usage debounce).
        for _ in $(seq 1 15); do
            [ "$(mic_lines)" -gt "$BEFORE" ] && break
            sleep 2
        done
        PEAK=$(newest_inpeak_after "$BEFORE")
        [ -z "$PEAK" ] && PEAK="none"
        # EC off: mic must clearly hear the speech. EC on: AEC cancels the
        # speaker sound by design — only EXACT zero is the dead-mic signature.
        THRESH=$([ "$EC" = 1 ] && echo "0.001" || echo "0.05")
        if [ "$PEAK" = "none" ]; then
            echo "  ✗ EC=$EC session $SESSION: no mic session ran"; FAILURES=$((FAILURES+1))
        elif [ "$(echo "$PEAK > $THRESH" | bc)" = "1" ]; then
            echo "  ✓ EC=$EC session $SESSION: inPeak=$PEAK"
        else
            echo "  ✗ EC=$EC session $SESSION: inPeak=$PEAK (dead capture)"; FAILURES=$((FAILURES+1))
        fi
        sleep 4
        # Mic must be RELEASED between sessions (no orange indicator).
        if "$CLI" micstatus >/dev/null 2>&1; then
            echo "  ✓ mic released after session $SESSION"
        else
            echo "  ✗ mic still held after session $SESSION"; FAILURES=$((FAILURES+1))
        fi
    done
done

# Restore: EC back off (current shipping default), leave the app running.
defaults write com.ode.app ode.echoCancel -bool false
osascript -e 'quit app "ODE"' 2>/dev/null; sleep 1; open dist/ODE.app

if [ "$FAILURES" = 0 ]; then
    echo "ALL MIC E2E CHECKS PASSED"
else
    echo "$FAILURES CHECK(S) FAILED"
    exit 1
fi
