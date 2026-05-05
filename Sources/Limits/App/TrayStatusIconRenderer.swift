import AppKit

@MainActor
final class TrayStatusIconRenderer {
    private let height: CGFloat = 22
    private let iconSize: CGFloat = 16.5
    private let iconTextSpacing: CGFloat = 4
    private let providerSpacing: CGFloat = 8
    private let horizontalInset: CGFloat = 1
    private let textTop: CGFloat = 1
    private let barTop: CGFloat = 17
    private let barHeight: CGFloat = 2
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11.2, weight: .semibold)
    private var iconCache: [TrayStatusProvider: NSImage] = [:]

    func image(for segments: [TrayStatusPresentationSegment]) -> NSImage? {
        guard !segments.isEmpty else { return nil }

        let attributes = textAttributes
        let measuredSegments = segments.map { segment in
            let size = (segment.metricText as NSString).size(withAttributes: attributes)
            return MeasuredSegment(
                segment: segment,
                textSize: size,
                icon: icon(for: segment.provider)
            )
        }
        let textWidth = measuredSegments.reduce(CGFloat.zero) { $0 + $1.textSize.width }
        let iconWidth = CGFloat(measuredSegments.count) * iconSize
        let internalSpacing = CGFloat(measuredSegments.count) * iconTextSpacing
        let providerGaps = CGFloat(max(0, measuredSegments.count - 1)) * providerSpacing
        let width = ceil(horizontalInset * 2 + textWidth + iconWidth + internalSpacing + providerGaps)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { [height, iconSize, iconTextSpacing, providerSpacing, horizontalInset, textTop, barTop, barHeight] _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            var x = horizontalInset

            for (index, measured) in measuredSegments.enumerated() {
                if index > 0 {
                    x += providerSpacing
                }

                if let icon = measured.icon {
                    icon.draw(
                        in: NSRect(
                            x: x,
                            y: floor((height - iconSize) / 2) - 1,
                            width: iconSize,
                            height: iconSize
                        ),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                }
                x += iconSize + iconTextSpacing

                measured.segment.metricText.draw(
                    with: NSRect(
                        x: x,
                        y: textTop,
                        width: measured.textSize.width,
                        height: measured.textSize.height
                    ),
                    options: [.usesLineFragmentOrigin],
                    attributes: attributes
                )
                Self.drawLimitBar(
                    remainingPercent: measured.segment.remainingPercent,
                    in: NSRect(
                        x: x,
                        y: barTop,
                        width: measured.textSize.width,
                        height: barHeight
                    )
                )
                x += measured.textSize.width
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
    }

    private func icon(for provider: TrayStatusProvider) -> NSImage? {
        if let cachedIcon = iconCache[provider] {
            return cachedIcon
        }

        guard let icon = TrayStatusIconAsset.image(for: provider) else {
            return nil
        }

        iconCache[provider] = icon
        return icon
    }

    private static func drawLimitBar(remainingPercent: Int?, in rect: NSRect) {
        guard rect.width > 2 else { return }

        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.white.withAlphaComponent(0.30).setFill()
        track.fill()

        guard let remainingPercent else { return }

        let normalized = min(100, max(0, remainingPercent))
        guard normalized > 0 else { return }
        let fillWidth = max(rect.height, rect.width * CGFloat(normalized) / 100)
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, fillWidth), height: rect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.white.withAlphaComponent(0.90).setFill()
        fill.fill()
    }
}

private struct MeasuredSegment {
    let segment: TrayStatusPresentationSegment
    let textSize: NSSize
    let icon: NSImage?
}
