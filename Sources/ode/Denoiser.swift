import CRNNoise

/// Thin Swift wrapper over RNNoise.
/// RNNoise operates on 48 kHz mono frames of `frameSize` samples,
/// expressed as floats in int16 scale (roughly -32768...32767).
final class Denoiser {
    private let state: OpaquePointer
    let frameSize: Int

    init() {
        self.state = rnnoise_create(nil)
        self.frameSize = Int(rnnoise_get_frame_size())
    }

    deinit {
        rnnoise_destroy(state)
    }

    /// Denoise a full buffer of normalized mono samples ([-1, 1], 48 kHz).
    /// Returns a new buffer of the same length. Trailing samples that do not
    /// fill a complete frame are passed through unprocessed.
    func process(_ samples: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        var frameIn = [Float](repeating: 0, count: frameSize)
        var frameOut = [Float](repeating: 0, count: frameSize)

        var i = 0
        while i + frameSize <= samples.count {
            for j in 0..<frameSize {
                frameIn[j] = samples[i + j] * 32768.0
            }
            _ = rnnoise_process_frame(state, &frameOut, &frameIn)
            for j in 0..<frameSize {
                out[i + j] = frameOut[j] / 32768.0
            }
            i += frameSize
        }
        // copy any remainder through untouched
        while i < samples.count {
            out[i] = samples[i]
            i += 1
        }
        return out
    }
}
