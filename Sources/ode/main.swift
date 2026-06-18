import Foundation
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
    do {
        try engine.start(outputDevice: target)
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

default:
    usage()
    exit(1)
}
