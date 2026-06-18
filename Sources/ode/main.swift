import Foundation

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

    EXAMPLES:
      ode file noisy.wav clean.wav
      ode mic 8 raw.wav clean.wav
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

default:
    usage()
    exit(1)
}
