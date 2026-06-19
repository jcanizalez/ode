#!/usr/bin/env python3
"""Seed fake ODE meetings so you can test the Meetings window without real calls.

Writes JSON (+ readable .txt) files ODE reads from:
  ~/Library/Application Support/ODE/Transcripts

Usage:
  scripts/seed-fake-transcripts.py            # add the sample meetings
  scripts/seed-fake-transcripts.py --clear    # wipe existing first, then add
"""
import json, os, sys, uuid, datetime, glob

DIR = os.path.expanduser("~/Library/Application Support/ODE/Transcripts")
os.makedirs(DIR, exist_ok=True)

def seg(speaker, start, end, text):
    return {"id": str(uuid.uuid4()), "speaker": speaker,
            "start": start, "end": end, "text": text}

def conv(pairs):
    """pairs: list of (speaker, text). Auto-assign ~5s timing."""
    out, t = [], 0
    for speaker, text in pairs:
        dur = max(2, min(9, len(text) // 12))
        out.append(seg(speaker, t, t + dur, text))
        t += dur + 1
    return out

def iso(dt):
    # dt is naive local time; convert to real UTC so ODE (which decodes ISO-8601
    # as UTC) displays the intended local time.
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def write(title, start_dt, segments, source_app, starred=False,
          summary=None, key_points=None, action_items=None, chat=None):
    end_dt = start_dt + datetime.timedelta(seconds=(segments[-1]["end"] + 2))
    uid = str(uuid.uuid4())
    t = {
        "id": uid, "title": title,
        "startedAt": iso(start_dt), "endedAt": iso(end_dt),
        "segments": segments, "sourceApp": source_app, "starred": starred,
    }
    if summary is not None: t["summary"] = summary
    if key_points is not None: t["keyPoints"] = key_points
    if action_items is not None: t["actionItems"] = action_items
    if chat:
        t["chat"] = [
            {"id": str(uuid.uuid4()), "question": q, "answer": a,
             "date": iso(start_dt + datetime.timedelta(minutes=i + 1))}
            for i, (q, a) in enumerate(chat)
        ]
    stem = start_dt.strftime("%Y%m%d_%H%M%S") + "_" + uid[:8]
    with open(os.path.join(DIR, stem + ".json"), "w") as f:
        json.dump(t, f, indent=2)
    print(f"  + {title}  ({source_app})")

if "--clear" in sys.argv:
    for p in glob.glob(os.path.join(DIR, "*.json")) + glob.glob(os.path.join(DIR, "*.txt")):
        os.remove(p)
    print(f"Cleared existing transcripts in {DIR}")

now = datetime.datetime.now()
def at(days_ago, h, m):
    d = (now - datetime.timedelta(days=days_ago)).replace(hour=h, minute=m, second=0, microsecond=0)
    return d

print(f"Seeding fake meetings into {DIR}")

# --- TODAY ---
write("Sprint Planning", at(0, 9, 2),
      conv([
        ("Others", "Morning everyone, let's plan the sprint. What's the priority?"),
        ("You", "I think shipping the noise cancellation polish is top of the list."),
        ("Others", "Agreed. We also need the meeting transcription feature done."),
        ("You", "I can take transcription. Should land by Thursday."),
        ("Others", "Perfect. Who owns the installer signing?"),
        ("You", "I'll handle notarization once the features are frozen."),
        ("Others", "Great, let's review progress on Wednesday."),
      ]),
      "Microsoft Teams", starred=True,
      summary="The team planned the current sprint, prioritizing the noise-cancellation polish and the meeting transcription feature. Ownership was assigned and a mid-sprint check-in was scheduled.",
      key_points=[
        "Noise-cancellation polish is the top priority.",
        "Meeting transcription is owned by You, due Thursday.",
        "Installer notarization happens after feature freeze.",
      ],
      action_items=[
        "You: finish meeting transcription by Thursday.",
        "You: notarize the installer after feature freeze.",
        "Team: review progress on Wednesday.",
      ],
      chat=[
        ("What did I commit to this sprint?",
         "You committed to finishing the meeting transcription feature by Thursday and notarizing the installer after the feature freeze."),
        ("Who owns the installer signing?",
         "You own the installer notarization, to be done after the features are frozen."),
        ("When is the next check-in?",
         "The team agreed to review progress on Wednesday."),
      ])

write("Design Review", at(0, 11, 30),
      conv([
        ("Others", "Thanks for joining. Walk me through the new panel."),
        ("You", "Two cards up top, You and Others, each with a live audio meter."),
        ("You", "Below that are the mic and speaker selectors, then transcripts."),
        ("Others", "Looks clean. Can we shrink the selected device text a bit?"),
        ("You", "Already fixed. Anything else?"),
        ("Others", "Nope, ship it. The glass effect looks fantastic."),
      ]),
      "Microsoft Teams",
      summary="A design review of the new control panel. The layout was approved with one minor tweak to device-text sizing, already addressed.",
      key_points=[
        "Panel: two metered cards, device selectors, transcripts row.",
        "Selected-device text was too large; now fixed.",
      ],
      action_items=["You: confirm the device-text fix is shipped."])

write("Customer Call — Acme", at(0, 14, 15),
      conv([
        ("Others", "Hi, thanks for the demo. Does ODE work with Zoom and Teams?"),
        ("You", "Yes — pick ODE Microphone and ODE Speaker as your devices in any app."),
        ("Others", "And transcripts stay on my machine? We have privacy requirements."),
        ("You", "Correct, transcription is fully on-device. Nothing is uploaded."),
        ("Others", "That's exactly what we need. How do we get started?"),
        ("You", "I'll send the one-click installer today."),
      ]),
      "zoom.us",
      summary="Acme evaluated ODE and confirmed it meets their privacy needs since transcription is fully on-device. They asked to get started; the installer will be sent today.",
      key_points=[
        "Works with Zoom and Teams via the ODE virtual devices.",
        "Transcription is on-device — nothing uploaded.",
        "Acme wants to proceed.",
      ],
      action_items=["You: send Acme the installer today."])

# --- YESTERDAY ---
write("1:1 with Manager", at(1, 16, 5),
      conv([
        ("Others", "How's the ODE project going?"),
        ("You", "Really well. Noise cancellation both directions works, transcription too."),
        ("Others", "Nice. Any blockers?"),
        ("You", "Just need a signing certificate for distribution."),
        ("Others", "I'll get that sorted this week."),
      ]),
      "Microsoft Teams", starred=True)

write("Standup", at(1, 9, 0),
      conv([
        ("You", "Yesterday I shipped the ODE Speaker device."),
        ("Others", "I tested it on a noisy call, sounded great."),
        ("You", "Today I'm on the Meetings window."),
        ("Others", "I'll pick up diarization research."),
      ]),
      "Microsoft Teams")

# --- EARLIER ---
write("Architecture Sync", at(3, 10, 2),
      conv([
        ("Others", "Let's talk about the denoise model choice."),
        ("You", "We benchmarked RNNoise, GTCRN and DPDFNet on a real clip."),
        ("You", "DPDFNet won — best quality with full-band audio."),
        ("Others", "And it's license-clean?"),
        ("You", "Yes, via sherpa-onnx, Apache licensed."),
        ("Others", "Great, let's standardize on it."),
      ]),
      "zoom.us",
      summary="The team reviewed denoising model options and standardized on DPDFNet (via sherpa-onnx) for its full-band quality and clean licensing.",
      key_points=[
        "Benchmarked RNNoise vs GTCRN vs DPDFNet on a real clip.",
        "DPDFNet chosen for quality and Apache licensing.",
      ],
      action_items=["Team: standardize on DPDFNet."],
      chat=[
        ("Why did we pick DPDFNet over RNNoise?",
         "DPDFNet was chosen because it delivered the best quality with full-band audio in the on-device benchmark, while remaining license-clean via sherpa-onnx (Apache)."),
        ("Is the model license commercial-friendly?",
         "Yes — DPDFNet is used through sherpa-onnx under the Apache license, which is commercial-friendly."),
      ])

print("Done. Open ODE → Transcripts (reopen the window to refresh).")
