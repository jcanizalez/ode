import Foundation
import AVFoundation
import ODEKit

func rms(_ s: [Float]) -> Float {
    guard !s.isEmpty else { return 0 }
    var acc: Float = 0
    for v in s { acc += v * v }
    return (acc / Float(s.count)).squareRoot()
}

func usage() {
    print("""
    ODE — Open Denoise Engine (Phase 1 CLI)

    USAGE:
      ode file <input-audio> <output.wav>
          Denoise an existing audio file.

      ode mic <seconds> <raw.wav> <clean.wav>
          Record from the default mic, write raw and denoised WAVs to compare.

      ode devices
          List CoreAudio input/output devices.

      ode live [--out "<device name>"]
          Real-time loop: capture mic -> denoise -> play to a device.
          With --out, routes clean audio into that device (e.g. "ODE Microphone").
          Without --out, monitors to the default output (use headphones).
          Press Ctrl-C to stop.

      ode fakecall --play <audio.wav> [--record <mic-out.wav>] [--seconds N]
          Impersonate a conferencing app: read from "ODE Microphone" and play
          the file into "ODE Speaker". Activates both denoise paths — and
          transcription, if enabled — exactly like a real call. With --record,
          saves what a call app would hear from you and reports audio glitches.
          Requires ODE.app to be running.

    EXAMPLES:
      ode file noisy.wav clean.wav
      ode mic 8 raw.wav clean.wav
      ode devices
      ode live --out "ODE Microphone"
    """)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(1) }

let denoiser = Denoiser()

switch args[1] {
case "file":
    guard args.count == 4 else { usage(); exit(1) }
    let inURL = URL(fileURLWithPath: args[2])
    let outURL = URL(fileURLWithPath: args[3])
    do {
        let samples = try AudioIO.readSamples(url: inURL)
        print("Read \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / AudioIO.sampleRate))s @48k mono)")
        let clean = denoiser.process(samples)
        try AudioIO.writeWav(samples: clean, url: outURL)
        print("Input RMS:  \(String(format: "%.5f", rms(samples)))")
        print("Output RMS: \(String(format: "%.5f", rms(clean)))")
        print("Wrote \(outURL.path)")
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "mic":
    guard args.count == 5, let secs = Double(args[2]) else { usage(); exit(1) }
    let rawURL = URL(fileURLWithPath: args[3])
    let cleanURL = URL(fileURLWithPath: args[4])
    do {
        print("Recording \(secs)s from default mic… (speak now)")
        let raw = try MicRecorder().record(seconds: secs)
        print("Captured \(raw.count) samples")
        guard !raw.isEmpty else {
            print("No audio captured — check mic permission (System Settings ▸ Privacy ▸ Microphone).")
            exit(1)
        }
        let clean = denoiser.process(raw)
        try AudioIO.writeWav(samples: raw, url: rawURL)
        try AudioIO.writeWav(samples: clean, url: cleanURL)
        print("Raw RMS:   \(String(format: "%.5f", rms(raw)))")
        print("Clean RMS: \(String(format: "%.5f", rms(clean)))")
        print("Wrote \(rawURL.path) and \(cleanURL.path)")
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "devices":
    let devs = AudioDevices.all()
    let defOut = AudioDevices.defaultOutput()?.id
    let defIn = AudioDevices.defaultInput()?.id
    print("CoreAudio devices:")
    for d in devs {
        var tags: [String] = []
        if d.hasInput { tags.append("in") }
        if d.hasOutput { tags.append("out") }
        if d.id == defIn { tags.append("DEFAULT-IN") }
        if d.id == defOut { tags.append("DEFAULT-OUT") }
        print("  • \(d.name)  [\(tags.joined(separator: ","))]")
    }

case "live":
    var outName: String? = nil
    var autoSeconds: Double? = nil
    if let idx = args.firstIndex(of: "--out"), idx + 1 < args.count {
        outName = args[idx + 1]
    }
    if let idx = args.firstIndex(of: "--seconds"), idx + 1 < args.count {
        autoSeconds = Double(args[idx + 1])
    }
    var target: AudioDevices.Device? = nil
    if let name = outName {
        guard let dev = AudioDevices.find(name: name) else {
            print("Output device not found: \(name)")
            print("Run 'ode devices' to list available devices.")
            exit(1)
        }
        guard dev.hasOutput else {
            print("Device '\(dev.name)' has no output channels.")
            exit(1)
        }
        target = dev
        print("Routing denoised audio -> \(dev.name)")
    } else {
        print("Monitoring denoised audio on default output (use headphones to avoid feedback).")
    }
    let engine = LiveEngine()
    let bypass = args.contains("--bypass")
    if bypass { print("Bypass mode: passing audio through WITHOUT denoising.") }
    do {
        try engine.start(outputDevice: target, bypass: bypass)
    } catch {
        print("Failed to start live engine: \(error.localizedDescription)")
        exit(1)
    }
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler {
        print("\nStopping…")
        engine.stop()
        exit(0)
    }
    src.resume()
    print("ODE live denoise running. Press Ctrl-C to stop.")
    if let secs = autoSeconds {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            print("Auto-stop after \(secs)s")
            engine.stop()
            exit(0)
        }
    }
    dispatchMain()

case "watch":
    // Debug: report input-usage of a device and observe changes.
    guard args.count >= 3 else { print("usage: ode watch \"<device name>\""); exit(1) }
    guard let dev = AudioDevices.find(name: args[2]) else {
        print("Device not found: \(args[2])"); exit(1)
    }
    print("Watching input usage of '\(dev.name)' (id \(dev.id)). Ctrl-C to stop.")
    print("  initial isInputInUse = \(AudioDevices.isInputInUse(dev.id))")
    setvbuf(stdout, nil, _IONBF, 0)
    let obs = AudioDevices.addUsageObserver(dev.id) { inUse in
        print("  [\(Date())] isInputInUse -> \(inUse)")
        fflush(stdout)
    }
    if obs == nil { print("  (failed to install observer)") }
    dispatchMain()

case "fakecall":
    // Impersonate a conferencing app so the whole ODE pipeline runs without a
    // real meeting: an input client on "ODE Microphone" (mic path activates)
    // and playback into "ODE Speaker" (speaker path activates).
    var playPath: String?
    var recordPath: String?
    var secondsArg: Double?
    if let i = args.firstIndex(of: "--play"), i + 1 < args.count { playPath = args[i + 1] }
    if let i = args.firstIndex(of: "--record"), i + 1 < args.count { recordPath = args[i + 1] }
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count { secondsArg = Double(args[i + 1]) }
    guard let playPath else {
        print("usage: ode fakecall --play <audio.wav> [--record <mic-out.wav>] [--seconds N]")
        exit(1)
    }

    // The visible devices only exist while ODE.app is running (they're hidden
    // otherwise), which is exactly what we want to verify.
    let visible = AudioDevices.all()
    guard let mic = visible.first(where: { $0.name.localizedCaseInsensitiveContains("ode microphone") }),
          let spk = visible.first(where: { $0.name.localizedCaseInsensitiveContains("ode speaker") }) else {
        print("ODE Microphone / ODE Speaker not found — is ODE.app running? (Devices are hidden while it isn't.)")
        exit(1)
    }

    func pinDevice(_ unit: AudioUnit?, _ id: AudioDeviceID) {
        guard let unit else { return }
        var dev = id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    do {
        // --- Input client on ODE Microphone (what Zoom would hear from you) ---
        let capture = AVAudioEngine()
        pinDevice(capture.inputNode.audioUnit, mic.id)
        let inFmt = capture.inputNode.inputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else {
            print("ODE Microphone has no valid format."); exit(1)
        }
        var recFile: AVAudioFile?
        if let recordPath {
            recFile = try AVAudioFile(forWriting: URL(fileURLWithPath: recordPath),
                                      settings: inFmt.settings)
        }
        // Glitch detector: abrupt sample-to-sample jumps are buffer skips/pops,
        // not speech (speech slew at 48 kHz is far smaller).
        var glitches = 0
        var capturedFrames: AVAudioFramePosition = 0
        var lastSample: Float = 0
        var peak: Float = 0
        capture.inputNode.installTap(onBus: 0, bufferSize: 4_800, format: inFmt) { buf, _ in
            capturedFrames += AVAudioFramePosition(buf.frameLength)
            try? recFile?.write(from: buf)
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<Int(buf.frameLength) {
                    if abs(ch[i] - lastSample) > 0.5 { glitches += 1 }
                    lastSample = ch[i]
                    let a = abs(ch[i])
                    if a > peak { peak = a }
                }
            }
        }
        try capture.start()
        print("▶ Reading ODE Microphone (\(mic.name))")

        // --- Playback client into ODE Speaker (the "incoming call audio") ---
        let playback = AVAudioEngine()
        let player = AVAudioPlayerNode()
        playback.attach(player)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: playPath))
        playback.connect(player, to: playback.mainMixerNode, format: file.processingFormat)
        pinDevice(playback.outputNode.audioUnit, spk.id)
        try playback.start()
        player.scheduleFile(file, at: nil)
        player.play()
        let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
        print("▶ Playing \(playPath) into ODE Speaker (\(String(format: "%.1f", fileSeconds))s)")

        let duration = secondsArg ?? (fileSeconds + 2)
        print("Simulated call running for \(String(format: "%.1f", duration))s…")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            player.stop()
            playback.stop()
            capture.inputNode.removeTap(onBus: 0)
            capture.stop()
            recFile = nil  // finalize the WAV header before exiting
            let secs = Double(capturedFrames) / inFmt.sampleRate
            print("✓ Call ended. Captured \(String(format: "%.1f", secs))s from ODE Microphone.")
            print(String(format: "  peak level: %.4f%@", peak,
                         peak == 0 ? "  ⚠ SILENT — mic path produced no audio!" : ""))
            print(glitches == 0
                  ? "✓ No audio glitches detected on the mic path."
                  : "⚠ \(glitches) abrupt discontinuities detected (possible pops).")
            if let recordPath { print("Mic-path recording: \(recordPath)") }
            exit(peak == 0 ? 2 : 0)
        }
        dispatchMain()
    } catch {
        print("fakecall error: \(error.localizedDescription)")
        exit(1)
    }

case "transcribe":
    // Debug: transcribe an audio file and print timestamped segments.
    // --engine picks the speech-to-text engine (default: apple).
    guard args.count >= 3 else {
        print("usage: ode transcribe <audio.wav> [--engine apple|parakeet] [--diarize]"); exit(1)
    }
    let url = URL(fileURLWithPath: args[2])
    var engineChoice = "apple"
    if let idx = args.firstIndex(of: "--engine"), idx + 1 < args.count {
        engineChoice = args[idx + 1]
    }
    let diarize = args.contains("--diarize")
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let t: any SpeechTranscribing
            switch engineChoice {
            case "parakeet":
                print("Ensuring Parakeet model (first run downloads the weights)…")
                try await ParakeetStreamTranscriber.ensureModel()
                t = ParakeetStreamTranscriber()
            case "apple":
                guard #available(macOS 26.0, *) else {
                    print("The apple engine requires macOS 26+. Try --engine parakeet.")
                    exit(1)
                }
                print("Ensuring Apple transcription model…")
                try await StreamTranscriber.ensureModel()
                t = StreamTranscriber()
            default:
                print("Unknown engine '\(engineChoice)' (use apple or parakeet)")
                exit(1)
            }
            var dz: SpeakerDiarizer?
            if diarize {
                print("Ensuring diarization model (first run downloads the weights)…")
                try await SpeakerDiarizer.ensureModel()
                let d = SpeakerDiarizer()
                try await d.start()
                dz = d
            }
            t.onSegment = { seg in
                var label = ""
                if let dz, seg.end > seg.start,
                   let spk = dz.speakerLabel(from: seg.start, to: seg.end) {
                    label = " \(spk):"
                }
                print(String(format: "[%6.2f–%6.2f]%@ %@", seg.start, seg.end, label, seg.text))
            }
            try await t.start()
            // Feed in ~1 s chunks to exercise the streaming path. (Guard on
            // framePosition: reading at EOF throws a generic ObjC error.)
            let file = try AVAudioFile(forReading: url)
            let fmt = file.processingFormat
            let chunkFrames = AVAudioFrameCount(fmt.sampleRate)
            while file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { break }
                try file.read(into: buf, frameCount: chunkFrames)
                if buf.frameLength == 0 { break }
                t.append(buf)
                dz?.append(buf)
            }
            dz?.finish()
            await t.finish()
            print("--- done ---")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()

default:
    usage()
    exit(1)
}
