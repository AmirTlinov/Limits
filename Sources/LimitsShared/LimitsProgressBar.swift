import SwiftUI

public struct LimitsProgressBar: View {
    private let progress: Double
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(progress: Double, tint: Color) {
        self.progress = progress
        self.tint = tint
    }

    public var body: some View {
        ProgressView(value: clampedProgress)
            .progressViewStyle(.linear)
            .tint(tint)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: clampedProgress)
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}
