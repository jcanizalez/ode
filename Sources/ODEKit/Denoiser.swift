import Foundation
import CSherpa

/// Locates the bundled DPDFNet model in both app-bundle and dev/CLI contexts.
enum ModelLocator {
    static func dpdfnetPath() -> String? {
        let name = "dpdfnet2_48khz_hr"
        let ext = "onnx"

        // 1. Inside an .app bundle (Resources/)
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url.path
        }

        let fm = FileManager.default
        var candidates: [String] = []

        // Environment override takes priority.
        if let env = ProcessInfo.processInfo.environment["ODE_MODEL_PATH"] {
            candidates.append(env)
        }

        // Next to the executable, and in Resources/ walking up from it.
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("\(name).\(ext)").path)
        var dir = exeDir
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Resources/\(name).\(ext)").path)
            dir.deleteLastPathComponent()
        }

        return candidates.first { fm.fileExists(atPath: $0) }
    }
}

/// Real-time speech denoiser backed by DPDFNet (via sherpa-onnx).
/// Replaces the earlier RNNoise implementation; the public API is unchanged so
/// callers (CLI, live engine, A/B tester) work without modification.
///
/// DPDFNet runs at 48 kHz full-band and preserves speech naturalness far better
/// than RNNoise while removing substantially more background noise.
public final class Denoiser {
    private let offline: OpaquePointer?
    private let online: OpaquePointer?
    private let modelPathC: [CChar]

    /// Frame granularity hint (kept for API compatibility with callers).
    public let frameSize: Int = 480 // 10 ms @ 48 kHz

    public init() {
        guard let path = ModelLocator.dpdfnetPath() else {
            fatalError("ODE: DPDFNet model not found. Expected "
                       + "Resources/dpdfnet2_48khz_hr.onnx next to the executable or in the "
                       + "app bundle. Set ODE_MODEL_PATH to override.")
        }
        modelPathC = path.cString(using: .utf8) ?? []

        offline = modelPathC.withUnsafeBufferPointer { buf in
            var cfg = SherpaOnnxOfflineSpeechDenoiserConfig()
            cfg.model.dpdfnet.model = buf.baseAddress
            cfg.model.num_threads = 2
            cfg.model.provider = ("cpu" as NSString).utf8String
            return SherpaOnnxCreateOfflineSpeechDenoiser(&cfg)
        }

        online = modelPathC.withUnsafeBufferPointer { buf in
            var cfg = SherpaOnnxOnlineSpeechDenoiserConfig()
            cfg.model.dpdfnet.model = buf.baseAddress
            cfg.model.num_threads = 1
            cfg.model.provider = ("cpu" as NSString).utf8String
            return SherpaOnnxCreateOnlineSpeechDenoiser(&cfg)
        }
    }

    deinit {
        if let o = offline { SherpaOnnxDestroyOfflineSpeechDenoiser(o) }
        if let o = online { SherpaOnnxDestroyOnlineSpeechDenoiser(o) }
    }

    /// Offline denoise of a complete 48 kHz mono buffer ([-1, 1]).
    public func process(_ samples: [Float]) -> [Float] {
        guard let offline, !samples.isEmpty else { return samples }
        let result = samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOfflineSpeechDenoiserRun(offline, buf.baseAddress, Int32(buf.count),
                                               Int32(AudioIO.sampleRate))
        }
        return Self.collect(result)
    }

    /// Streaming denoise: feed arbitrary-length 48 kHz chunks across calls;
    /// returns whatever denoised output is ready this call.
    public func processStreaming(_ chunk: [Float]) -> [Float] {
        guard let online, !chunk.isEmpty else { return [] }
        let result = chunk.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineSpeechDenoiserRun(online, buf.baseAddress, Int32(buf.count),
                                              Int32(AudioIO.sampleRate))
        }
        return Self.collect(result)
    }

    /// Flush any buffered streaming audio (call when stopping a live session).
    public func flushStreaming() -> [Float] {
        guard let online else { return [] }
        return Self.collect(SherpaOnnxOnlineSpeechDenoiserFlush(online))
    }

    // MARK: - Helpers

    private static func collect(_ result: UnsafePointer<SherpaOnnxDenoisedAudio>?) -> [Float] {
        guard let result else { return [] }
        let audio = result.pointee
        let n = Int(audio.n)
        let out: [Float]
        if n > 0, let s = audio.samples {
            out = Array(UnsafeBufferPointer(start: s, count: n))
        } else {
            out = []
        }
        SherpaOnnxDestroyDenoisedAudio(result)
        return out
    }
}
