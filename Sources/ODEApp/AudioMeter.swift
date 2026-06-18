import SwiftUI

/// A small animated bar meter driven by a 0...1 level. Each bar has its own
/// baseline weight so it looks lively, scaled by the current level.
struct AudioMeter: View {
    var level: Float          // 0...1
    var active: Bool
    var color: Color

    private let weights: [CGFloat] = [0.45, 0.8, 0.55, 1.0, 0.7, 0.35]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                let base = weights[i]
                let h = active ? max(0.12, CGFloat(level) * base) : 0.12
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? color : color.opacity(0.25))
                    .frame(width: 3.5, height: 4 + h * 22)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 26, alignment: .bottom)
    }
}
