import Foundation
import os
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
    /// The two inference sessions are built ON FIRST USE, not at init: each one
    /// loads its own copy of the 10.6 MB model into an ONNX Runtime arena (and
    /// the offline one spins up a 2-thread pool), and every owner uses exactly
    /// one of them — LiveEngine only streams, the CLI and the A/B tester only
    /// process whole buffers. Building both eagerly meant the two engines
    /// ODEController constructs at launch held four sessions where two would
    /// do, before a single call had started.
    private var lock = os_unfair_lock()
    private var _offline: OpaquePointer?
    private var _online: OpaquePointer?
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
    }

    /// Whole-buffer session, created on first use.
    private func offlineSession() -> OpaquePointer? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if _offline == nil {
            _offline = modelPathC.withUnsafeBufferPointer { buf in
                var cfg = SherpaOnnxOfflineSpeechDenoiserConfig()
                cfg.model.dpdfnet.model = buf.baseAddress
                cfg.model.num_threads = 2
                cfg.model.provider = ("cpu" as NSString).utf8String
                return SherpaOnnxCreateOfflineSpeechDenoiser(&cfg)
            }
        }
        return _offline
    }

    /// Streaming session, created on first use.
    private func onlineSession() -> OpaquePointer? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if _online == nil {
            _online = modelPathC.withUnsafeBufferPointer { buf in
                var cfg = SherpaOnnxOnlineSpeechDenoiserConfig()
                cfg.model.dpdfnet.model = buf.baseAddress
                cfg.model.num_threads = 1
                cfg.model.provider = ("cpu" as NSString).utf8String
                return SherpaOnnxCreateOnlineSpeechDenoiser(&cfg)
            }
        }
        return _online
    }

    /// The streaming session ONLY if it already exists — reset/flush must not
    /// build one just to tear it down (LiveEngine.teardown calls both on every
    /// session end, including sessions that never denoised anything).
    private func existingOnlineSession() -> OpaquePointer? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _online
    }

    deinit {
        if let o = _offline { SherpaOnnxDestroyOfflineSpeechDenoiser(o) }
        if let o = _online { SherpaOnnxDestroyOnlineSpeechDenoiser(o) }
    }

    /// Offline denoise of a complete 48 kHz mono buffer ([-1, 1]).
    public func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, let offline = offlineSession() else { return samples }
        let result = samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOfflineSpeechDenoiserRun(offline, buf.baseAddress, Int32(buf.count),
                                               Int32(AudioIO.sampleRate))
        }
        return Self.collect(result)
    }

    /// Streaming denoise: feed arbitrary-length 48 kHz chunks across calls;
    /// returns whatever denoised output is ready this call.
    public func processStreaming(_ chunk: [Float]) -> [Float] {
        guard !chunk.isEmpty, let online = onlineSession() else { return [] }
        let result = chunk.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineSpeechDenoiserRun(online, buf.baseAddress, Int32(buf.count),
                                              Int32(AudioIO.sampleRate))
        }
        return Self.collect(result)
    }

    /// Flush any buffered streaming audio (call when stopping a live session).
    public func flushStreaming() -> [Float] {
        guard let online = existingOnlineSession() else { return [] }
        return Self.collect(SherpaOnnxOnlineSpeechDenoiserFlush(online))
    }

    /// Reset the streaming denoiser's internal state so a new session starts
    /// clean (call between calls to avoid carrying stale state).
    public func resetStreaming() {
        guard let online = existingOnlineSession() else { return }
        SherpaOnnxOnlineSpeechDenoiserReset(online)
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
