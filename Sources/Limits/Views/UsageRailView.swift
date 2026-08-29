import AppKit
import SwiftUI
import LimitsCore
import LimitsShared

/// Geometry transcribed from the reference mockup. Every length below is the measurement
/// taken off that image in its own pixels, scaled once — so the rail keeps the mockup's
/// proportions exactly and the whole surface resizes by changing `scale` alone.
/// The window controller sizes the panel from the same numbers, which keeps the rail's
/// screen position stable while the bubble opens and closes.
enum UsageRailMetrics {
    /// The mockup draws the ring 90px across; this renders it at 52pt.
    static let scale: CGFloat = 52.0 / 90.0

    private static func mockup(_ pixels: CGFloat) -> CGFloat {
        (pixels * scale).rounded()
    }

    // Rail
    static let railWidth = mockup(143)          // 83
    static let ringDiameter = mockup(90)        // 52
    static let ringStroke = mockup(12)          // 7
    static let ringGlyph = mockup(41)           // 24
    /// Concave notch and pill corner meet directly: there is no flat top edge on the rail.
    static let notchRadius = mockup(86)         // 50
    static let cornerRadius = mockup(56)        // 32
    static let railVerticalPadding = mockup(125) // 72
    static let labelSpacing = mockup(21)        // 12
    static let cellSpacing = mockup(62)         // 36

    // Bubble
    static let bubbleBodyWidth = mockup(460)    // 266
    static let bubbleCornerRadius = mockup(36)  // 21
    static let bubbleTailLength = mockup(51)    // 29
    static let bubbleTailHalfHeight = mockup(45) // 26
    static let bubbleGap = mockup(28)           // 16
    static let bubbleLeadingPadding = mockup(19) // 11
    static let bubbleTrailingPadding = mockup(28) // 16
    static let bubbleTopPadding = mockup(24)    // 14
    static let bubbleBottomPadding = mockup(24) // 14
    static let bubbleHeaderGlyph = mockup(35)   // 20
    static let bubbleHeaderGlyphGap = mockup(13) // 8
    static let bubbleRowSpacing = mockup(17)    // 10
    static let bubbleTitleToBar = mockup(11)    // 6
    static let bubbleBarToUsed = mockup(16)     // 9
    static let bubbleBarHeight = mockup(8)      // 5

    /// Font sizes come from the mockup's measured ink heights divided by SF's cap ratio.
    static let percentFontSize = mockup(33)     // 19
    static let bubbleHeaderFontSize = mockup(26) // 15
    static let bubbleTitleFontSize = mockup(19) // 11
    static let bubbleUsedFontSize = mockup(18)  // 10
    static let bubbleResetFontSize = mockup(17) // 10

    static var bubbleFrameWidth: CGFloat { bubbleBodyWidth + bubbleTailLength }

    /// Width the panel needs while a bubble is open.
    static var expandedWidth: CGFloat { railWidth + bubbleGap + bubbleFrameWidth }

    /// Distance from a ring's centre to the centre of its bubble, which sits left of the rail.
    static var bubbleOffset: CGFloat { -(railWidth / 2 + bubbleGap + bubbleFrameWidth / 2) }
}

/// Sampled straight out of the mockup rather than derived from opacities. The mockup is a
/// Display P3 capture, so the samples are declared in P3 too — read as sRGB they would come
/// back noticeably desaturated on a wide-gamut screen.
enum UsageRailPalette {
    private static func sample(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.displayP3, red: red / 255, green: green / 255, blue: blue / 255)
    }

    static let surface = Color.black
    static let track = sample(48, 48, 48)
    static let barTrack = sample(45, 45, 45)
    static let secondaryText = sample(129, 129, 129)

    static let green = sample(117, 250, 145)
    static let yellow = sample(244, 252, 64)
    static let orange = sample(234, 84, 30)
    /// The mockup has no sample above 90%; this continues the ramp past its orange.
    static let red = sample(250, 60, 45)
}

extension UsageRailSeverity {
    var railColor: Color {
        switch self {
        case .unknown: UsageRailPalette.track
        case .low: UsageRailPalette.green
        case .medium: UsageRailPalette.yellow
        case .high: UsageRailPalette.orange
        case .critical: UsageRailPalette.red
        }
    }
}

extension LimitsWidgetProviderID {
    /// Nil for a provider the icon set does not cover, so the glyph can fall back to text.
    var trayProvider: TrayStatusProvider? {
        switch self {
        case .codex: .codex
        case .claude: .claude
        @unknown default: nil
        }
    }
}

/// Right-edge silhouette: a pill flush against the screen edge whose top and bottom sweep
/// back out to that edge. The concave notch runs straight into the pill's rounded corner —
/// in the mockup the two arcs meet with no flat top edge between them.
struct UsageRailShape: Shape {
    var cornerRadius: CGFloat = UsageRailMetrics.cornerRadius
    var notchRadius: CGFloat = UsageRailMetrics.notchRadius

    func path(in rect: CGRect) -> Path {
        let notch = min(notchRadius, rect.height / 2, rect.width)
        let corner = min(cornerRadius, rect.width - notch, max((rect.height - 2 * notch) / 2, 0))
        let bodyTop = rect.minY + notch
        let bodyBottom = rect.maxY - notch

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: bodyBottom - corner))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: bodyTop),
            tangent2End: CGPoint(x: rect.maxX - notch, y: bodyTop),
            radius: corner
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: bodyTop),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: notch
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: bodyBottom),
            tangent2End: CGPoint(x: rect.maxX - notch, y: bodyBottom),
            radius: notch
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: bodyBottom),
            tangent2End: CGPoint(x: rect.minX, y: bodyTop),
            radius: corner
        )
        path.closeSubpath()
        return path
    }
}

/// Rounded card with a broad, curved tail on its right edge pointing at the ring. The tail
/// flares out slowly and then rushes to the point, matching the mockup's profile.
struct UsageRailBubbleShape: Shape {
    var cornerRadius: CGFloat = UsageRailMetrics.bubbleCornerRadius
    var tailLength: CGFloat = UsageRailMetrics.bubbleTailLength
    var tailHalfHeight: CGFloat = UsageRailMetrics.bubbleTailHalfHeight

    func path(in rect: CGRect) -> Path {
        let bodyWidth = max(rect.width - tailLength, 0)
        let body = CGRect(x: rect.minX, y: rect.minY, width: bodyWidth, height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)

        let half = min(tailHalfHeight, max(rect.height / 2 - cornerRadius, 0))
        guard half > 0, tailLength > 0 else { return path }

        let edge = body.maxX
        let midY = rect.midY
        let tip = CGPoint(x: rect.maxX, y: midY)

        var tail = Path()
        tail.move(to: CGPoint(x: edge, y: midY - half))
        tail.addCurve(
            to: tip,
            control1: CGPoint(x: edge + tailLength * 0.08, y: midY - half * 0.62),
            control2: CGPoint(x: edge + tailLength * 0.55, y: midY - half * 0.12)
        )
        tail.addCurve(
            to: CGPoint(x: edge, y: midY + half),
            control1: CGPoint(x: edge + tailLength * 0.55, y: midY + half * 0.12),
            control2: CGPoint(x: edge + tailLength * 0.08, y: midY + half * 0.62)
        )
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}

struct UsageRailRootView: View {
    @ObservedObject var model: AppModel
    let onHoverChange: (LimitsWidgetProviderID?) -> Void
    let onHeightChange: (CGFloat) -> Void
    let openAccountsWindow: () -> Void

    @State private var hovered: LimitsWidgetProviderID?

    private var items: [UsageRailItem] {
        UsageRailPresentation.items(
            from: model.usageRailInputs(now: model.presentationNow),
            now: model.presentationNow
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            UsageRailColumn(
                items: items,
                hovered: $hovered,
                openAccountsWindow: openAccountsWindow
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onHeightChange(height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onChange(of: hovered) { _, newValue in
            onHoverChange(newValue)
        }
        .onChange(of: items.map(\.id)) { _, identifiers in
            if let hovered, !identifiers.contains(hovered) {
                self.hovered = nil
            }
        }
    }
}

private struct UsageRailColumn: View {
    let items: [UsageRailItem]
    @Binding var hovered: LimitsWidgetProviderID?
    let openAccountsWindow: () -> Void

    var body: some View {
        VStack(spacing: UsageRailMetrics.cellSpacing) {
            ForEach(items) { item in
                UsageRailCell(
                    item: item,
                    isHovered: hovered == item.id,
                    hoverChanged: { isInside in
                        if isInside {
                            hovered = item.id
                        } else if hovered == item.id {
                            hovered = nil
                        }
                    },
                    clicked: openAccountsWindow
                )
            }
        }
        .padding(.vertical, UsageRailMetrics.railVerticalPadding)
        .frame(width: UsageRailMetrics.railWidth)
        .background(UsageRailShape().fill(UsageRailPalette.surface))
    }
}

private struct UsageRailCell: View {
    let item: UsageRailItem
    let isHovered: Bool
    let hoverChanged: (Bool) -> Void
    let clicked: () -> Void

    var body: some View {
        VStack(spacing: UsageRailMetrics.labelSpacing) {
            UsageRailRing(item: item)
                .frame(width: UsageRailMetrics.ringDiameter, height: UsageRailMetrics.ringDiameter)
                .overlay(alignment: .center) {
                    if isHovered {
                        UsageRailBubble(item: item)
                            .frame(width: UsageRailMetrics.bubbleFrameWidth)
                            .offset(x: UsageRailMetrics.bubbleOffset)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }

            // No `minimumScaleFactor` here: it shrank the percentage well below the mockup's
            // size, and the widest string this ever shows ("100%") fits the rail already.
            Text(item.metricText)
                .font(.system(size: UsageRailMetrics.percentFontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(item.isStale ? Color.white.opacity(0.55) : .white)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: UsageRailMetrics.railWidth)
        .contentShape(Rectangle())
        .background(RailPointerTracker(hoverChanged: hoverChanged, clicked: clicked))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

private struct UsageRailRing: View {
    let item: UsageRailItem

    var body: some View {
        ZStack {
            Circle()
                .inset(by: UsageRailMetrics.ringStroke / 2)
                .stroke(UsageRailPalette.track, lineWidth: UsageRailMetrics.ringStroke)

            Circle()
                .inset(by: UsageRailMetrics.ringStroke / 2)
                .trim(from: 0, to: item.progressValue)
                .stroke(
                    item.severity.railColor,
                    style: StrokeStyle(lineWidth: UsageRailMetrics.ringStroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // Last known numbers stay visible but read as dimmer than a current reading.
                .opacity(item.isStale ? 0.55 : 1)

            UsageRailGlyph(provider: item.id)
                .frame(width: UsageRailMetrics.ringGlyph, height: UsageRailMetrics.ringGlyph)
                .foregroundStyle(.white)
        }
    }
}

struct UsageRailGlyph: View {
    let provider: LimitsWidgetProviderID

    var body: some View {
        if let trayProvider = provider.trayProvider,
           let image = TrayStatusIconAsset.railImage(for: trayProvider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Text(String(provider.appearance.shortTitle.prefix(1)))
                .font(.system(size: UsageRailMetrics.ringGlyph * 0.7, weight: .bold))
        }
    }
}

private struct UsageRailBubble: View {
    let item: UsageRailItem

    var body: some View {
        VStack(alignment: .leading, spacing: UsageRailMetrics.bubbleRowSpacing) {
            HStack(spacing: UsageRailMetrics.bubbleHeaderGlyphGap) {
                UsageRailGlyph(provider: item.id)
                    .frame(
                        width: UsageRailMetrics.bubbleHeaderGlyph,
                        height: UsageRailMetrics.bubbleHeaderGlyph
                    )
                    .foregroundStyle(.white)

                Text(item.headerText)
                    .font(.system(size: UsageRailMetrics.bubbleHeaderFontSize))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            if item.groups.isEmpty {
                Text(item.note ?? L10n.tr("rail.no_data"))
                    .font(.system(size: UsageRailMetrics.bubbleTitleFontSize))
                    .foregroundStyle(UsageRailPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(item.groups) { group in
                    if item.showsAccountTitles {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(group.title)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            // Each account carries its own age, so one being current cannot
                            // make another look current.
                            if let updatedText = group.updatedText {
                                Spacer(minLength: 6)
                                Text(updatedText).lineLimit(1)
                            }
                        }
                        .font(.system(size: UsageRailMetrics.bubbleResetFontSize))
                        .foregroundStyle(UsageRailPalette.secondaryText)
                    }

                    ForEach(group.rows) { row in
                        UsageRailBubbleRow(row: row)
                    }
                }
            }

            // With one account there is no title line to hang the age on.
            if !item.showsAccountTitles, let updatedText = item.updatedText {
                Text(updatedText)
                    .font(.system(size: UsageRailMetrics.bubbleResetFontSize))
                    .foregroundStyle(UsageRailPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.leading, UsageRailMetrics.bubbleLeadingPadding)
        .padding(.trailing, UsageRailMetrics.bubbleTrailingPadding + UsageRailMetrics.bubbleTailLength)
        .padding(.top, UsageRailMetrics.bubbleTopPadding)
        .padding(.bottom, UsageRailMetrics.bubbleBottomPadding)
        .background(UsageRailBubbleShape().fill(UsageRailPalette.surface))
    }
}

private struct UsageRailBubbleRow: View {
    let row: UsageRailLimitRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.system(size: UsageRailMetrics.bubbleTitleFontSize))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let resetText = row.resetText {
                    Text(resetText)
                        .font(.system(size: UsageRailMetrics.bubbleResetFontSize))
                        .foregroundStyle(UsageRailPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.bottom, UsageRailMetrics.bubbleTitleToBar)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(UsageRailPalette.barTrack)

                    Capsule()
                        .fill(row.severity.railColor)
                        .frame(
                            width: max(
                                proxy.size.width * row.progressValue,
                                row.progressValue > 0 ? UsageRailMetrics.bubbleBarHeight : 0
                            )
                        )
                }
            }
            .frame(height: UsageRailMetrics.bubbleBarHeight)
            .padding(.bottom, UsageRailMetrics.bubbleBarToUsed)

            Text(row.usedText)
                .font(.system(size: UsageRailMetrics.bubbleUsedFontSize))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}

/// SwiftUI's `onHover` only tracks while the app is active; the rail has to react while any
/// other app is frontmost, so hover and clicks come from an always-active tracking area.
private struct RailPointerTracker: NSViewRepresentable {
    let hoverChanged: (Bool) -> Void
    let clicked: () -> Void

    func makeNSView(context: Context) -> RailPointerTrackingView {
        RailPointerTrackingView(hoverChanged: hoverChanged, clicked: clicked)
    }

    func updateNSView(_ nsView: RailPointerTrackingView, context: Context) {
        nsView.hoverChanged = hoverChanged
        nsView.clicked = clicked
    }
}

final class RailPointerTrackingView: NSView {
    var hoverChanged: (Bool) -> Void
    var clicked: () -> Void
    private var installedTrackingArea: NSTrackingArea?

    init(hoverChanged: @escaping (Bool) -> Void, clicked: @escaping () -> Void) {
        self.hoverChanged = hoverChanged
        self.clicked = clicked
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RailPointerTrackingView is not available from a nib")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let installedTrackingArea {
            removeTrackingArea(installedTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        installedTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        hoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        clicked()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
