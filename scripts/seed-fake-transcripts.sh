#!/bin/sh
# Seed fake meeting transcripts so you can test the Meeting Notes UI without a
# real call. Writes JSON + .txt files ODE can read into
#   ~/Library/Application Support/ODE/Transcripts
#
# Usage:
#   ./scripts/seed-fake-transcripts.sh          # add 3 sample meetings
#   ./scripts/seed-fake-transcripts.sh --clear  # remove all transcripts first

DIR="$HOME/Library/Application Support/ODE/Transcripts"
mkdir -p "$DIR"

if [ "$1" = "--clear" ]; then
    rm -f "$DIR"/*.json "$DIR"/*.txt
    echo "Cleared existing transcripts in $DIR"
fi

# write_transcript <uuid> <title> <iso_start> <iso_end> <segments_json>
write_transcript() {
    uuid="$1"; title="$2"; start="$3"; end="$4"; segs="$5"
    stem="$(echo "$start" | tr -d ':-' | tr 'T' '_')_${uuid%%-*}"
    cat > "$DIR/$stem.json" <<JSON
{
  "id" : "$uuid",
  "title" : "$title",
  "startedAt" : "$start",
  "endedAt" : "$end",
  "segments" : $segs
}
JSON
    echo "  + $title"
}

seg() { # speaker start end text -> one JSON object
    printf '{ "id":"%s", "speaker":"%s", "start":%s, "end":%s, "text":"%s" }' \
        "$(uuidgen)" "$1" "$2" "$3" "$4"
}

echo "Seeding fake transcripts into $DIR"

# --- Meeting 1: standup ---
S1="[
  $(seg You 0 4 "Morning everyone, quick standup. I will start."),
  $(seg You 5 11 "Yesterday I finished the ODE Speaker device and wired up the transcription engine."),
  $(seg Others 12 17 "Nice. I tested the noise cancellation on a noisy cafe call, it sounded really clean."),
  $(seg You 18 23 "Great. Today I am polishing the panel UI and the meeting notes view."),
  $(seg Others 24 29 "I will look into the multi-speaker diarization follow-up. Anything blocking you?"),
  $(seg You 30 33 "Nothing blocking. Let us sync after lunch.")
]"
write_transcript "$(uuidgen)" "9:02 AM Standup" "2026-06-18T15:02:00Z" "2026-06-18T15:08:00Z" "$S1"

# --- Meeting 2: design review ---
S2="[
  $(seg Others 0 6 "Thanks for joining the design review. Walk me through the new panel."),
  $(seg You 7 14 "Sure. Two cards at the top, You and Others, each with a live audio meter and a toggle."),
  $(seg You 15 20 "Below are the microphone and speaker selectors, then the transcripts row."),
  $(seg Others 21 27 "I like it. Can we make the selected device text a little smaller though?"),
  $(seg You 28 31 "Already on it. Good catch."),
  $(seg Others 32 38 "Perfect. Ship it once that is in. The glass effect looks fantastic.")
]"
write_transcript "$(uuidgen)" "11:30 AM Design Review" "2026-06-18T17:30:00Z" "2026-06-18T17:42:00Z" "$S2"

# --- Meeting 3: customer call ---
S3="[
  $(seg Others 0 5 "Hi, thanks for the demo. Does ODE work with Zoom and Teams?"),
  $(seg You 6 12 "Yes. You pick ODE Microphone as your mic and ODE Speaker as your speaker in any app."),
  $(seg Others 13 18 "And transcripts stay on my machine? We have privacy requirements."),
  $(seg You 19 26 "Correct. Transcription runs fully on-device with the Apple speech engine. Nothing is uploaded."),
  $(seg Others 27 31 "That is exactly what we need. How do we get started?"),
  $(seg You 32 37 "I will send you the installer. One click installs the app and the virtual devices.")
]"
write_transcript "$(uuidgen)" "2:15 PM Customer Call" "2026-06-18T20:15:00Z" "2026-06-18T20:34:00Z" "$S3"

echo "Done. Open ODE menu bar -> Meeting Notes (reopen the window to refresh)."
