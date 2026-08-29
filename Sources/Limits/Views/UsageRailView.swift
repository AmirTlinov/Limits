import AppKit
import SwiftUI
import LimitsCore
import LimitsShared

/// Fixed geometry for the floating rail. The window controller sizes the panel from the
/// same numbers, so the rail keeps a stable screen position while the bubble opens and closes.
enum UsageRailMetrics {
    static let ringDiameter: CGFloat = 52
    static let ringLineWidth: CGFloat = 4
    static let labelSpacing: CGFloat = 5
    static let cellSpacing: CGFloat = 18
    static let railWidth: CGFloat = 92
    static let cornerRadius: CGFloat = 30
    static let notchRadius: CGFloat = 22
    static let contentVerticalPadding: CGFloat = 18
    static let bubbleWidth: CGFloat = 262
    static let bubbleGap: CGFloat = 10

    /// The notches sit outside the pill body, so the rings have to clear them as well as the
    /// padding — otherwise the first and last ring spill past the black background.
    static let railVerticalPadding: CGFloat = notchRadius + contentVerticalPadding

    /// Width the panel needs while a bubble is open.
    static let expandedWidth: CGFloat = railWidth + bubbleGap + bubbleWidth

    /// Distance from a ring's centre to the centre of its bubble, which sits left of the rail.
    static let bubbleOffset: CGFloat = -(railWidth / 2 + bubbleGap + bubbleWidth / 2)
}

extension UsageRailSeverity {
    var railColor: Color {
        switch self {
        case .unknown:
            return Color.white.opacity(0.28)
        case .low:
            return Color(red: 0.26, green: 0.85, blue: 0.40)
        case .medium:
            return Color(red: 0.87, green: 0.89, blue: 0.20)
        case .high:
            return Color(red: 0.98, green: 0.36, blue: 0.14)
        case .critical:
            return Color(red: 1.00, green: 0.23, blue: 0.19)
        }
    }
}

extension LimitsWidgetProviderID {
    /// Nil for a provider the tray icon set does not cover, so the glyph can fall back to text.
    var trayProvider: TrayStatusProvider? {
        switch self {
        case .codex: .codex
        case .claude: .claude
        @unknown default: nil
        }
    }
}

/// Right-edge silhouette: a pill flush against the screen edge whose top and bottom blend
/// back out to that edge through inverted (concave) corners.
struct UsageRailShape: Shape {
    var cornerRadius: CGFloat = UsageRailMetrics.cornerRadius
    var notchRadius: CGFloat = UsageRailMetrics.notchRadius

    func path(in rect: CGRect) -> Path {
        let notch = min(notchRadius, rect.height / 2, rect.width)
        let corner = min(cornerRadius, rect.width, (rect.height - 2 * notch) / 2)
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

/// Rounded card with a tail pointing right, at the vertical centre of the card.
struct UsageRailBubbleShape: Shape {
    var cornerRadius: CGFloat = 16
    var tailWidth: CGFloat = 11
    var tailHeight: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(rect.width - tailWidth, 0),
            height: rect.height
        )
        var path = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)

        var tail = Path()
        let midY = rect.midY
        tail.move(to: CGPoint(x: body.maxX - cornerRadius, y: midY - tailHeight / 2))
        tail.addLine(to: CGPoint(x: rect.maxX, y: midY))
        tail.addLine(to: CGPoint(x: body.maxX - cornerRadius, y: midY + tailHeight / 2))
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
            from: model.makeWidgetSnapshot(now: model.presentationNow),
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
        .background(UsageRailShape().fill(Color.black.opacity(0.92)))
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
                            .frame(width: UsageRailMetrics.bubbleWidth)
                            .offset(x: UsageRailMetrics.bubbleOffset)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }

            Text(item.metricText)
                .font(.system(size: 17, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
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
                .fill(Color.white.opacity(0.10))

            Circle()
                .strokeBorder(Color.white.opacity(0.13), lineWidth: UsageRailMetrics.ringLineWidth)

            Circle()
                .inset(by: UsageRailMetrics.ringLineWidth / 2)
                .trim(from: 0, to: item.progressValue)
                .stroke(
                    item.severity.railColor,
                    style: StrokeStyle(lineWidth: UsageRailMetrics.ringLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            UsageRailGlyph(provider: item.id)
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
        }
    }
}

struct UsageRailGlyph: View {
    let provider: LimitsWidgetProviderID

    var body: some View {
        if let trayProvider = provider.trayProvider,
           let image = TrayStatusIconAsset.image(for: trayProvider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Text(String(provider.appearance.shortTitle.prefix(1)))
                .font(.system(size: 14, weight: .bold))
        }
    }
}

private struct UsageRailBubble: View {
    let item: UsageRailItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                UsageRailGlyph(provider: item.id)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.white)

                Text(item.headerText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            if item.rows.isEmpty {
                Text(item.note ?? L10n.tr("rail.no_data"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(item.rows) { row in
                    UsageRailBubbleRow(row: row)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14 + UsageRailBubbleShape().tailWidth)
        .padding(.vertical, 12)
        .background(UsageRailBubbleShape().fill(Color.black.opacity(0.92)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.32), radius: 12, y: 4)
    }
}

private struct UsageRailBubbleRow: View {
    let row: UsageRailLimitRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let resetText = row.resetText {
                    Text(resetText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))

                    Capsule()
                        .fill(row.severity.railColor)
                        .frame(width: max(proxy.size.width * row.progressValue, row.progressValue > 0 ? 4 : 0))
                }
            }
            .frame(height: 5)

            Text(row.usedText)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
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
