import AppKit

@MainActor
final class TrayStatusIconRenderer {
    private let height: CGFloat = 18
    private let iconSize: CGFloat = 12.5
    private let iconTextSpacing: CGFloat = 4
    private let providerSpacing: CGFloat = 8
    private let horizontalInset: CGFloat = 1
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
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { [height, iconSize, iconTextSpacing, providerSpacing, horizontalInset] _ in
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
                            y: floor((height - iconSize) / 2),
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
                        y: floor((height - measured.textSize.height) / 2),
                        width: measured.textSize.width,
                        height: measured.textSize.height
                    ),
                    options: [.usesLineFragmentOrigin],
                    attributes: attributes
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
}

private struct MeasuredSegment {
    let segment: TrayStatusPresentationSegment
    let textSize: NSSize
    let icon: NSImage?
}
