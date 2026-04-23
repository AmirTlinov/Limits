import SwiftUI

struct CurrentCLIOverviewCard: View {
    let overview: AppModel.CurrentCLIOverview
    let source: AppModel.CurrentCLIState.Source
    let compactRows: [RateLimitDisplayRow]
    let updatedAt: Date?
    let isBusy: Bool
    let busyMessage: String?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(overview.title)
                        .font(compact ? .headline : .title3.weight(.semibold))
                        .lineLimit(1)

                    if let subtitle = overview.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let badgeSource {
                    CLIStateBadge(source: badgeSource)
                }
            }

            if compact, !compactRows.isEmpty {
                CompactLimitBarsView(rows: compactRows)
            } else if let limits = overview.limits {
                Text(limits)
                    .font(compact ? .system(size: 14, weight: .semibold, design: .rounded) : .system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let note = overview.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(noteColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isBusy || updatedAtText != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isBusy, let busyMessage {
                        Text(busyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if let updatedAtText {
                        Text(updatedAtText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundShape)
    }

    private var noteColor: Color {
        switch source {
        case .stored:
            return .secondary
        case .external:
            return .secondary
        case .missing:
            return .secondary
        case .unreadable:
            return .red
        }
    }

    private var badgeSource: AppModel.CurrentCLIState.Source? {
        if compact {
            switch source {
            case .stored, .external:
                return nil
            case .missing, .unreadable:
                return source
            }
        }

        return source
    }

    private var updatedAtText: String? {
        guard let updatedAt else { return nil }
        return "Обновлено \(Self.updatedAtText(for: updatedAt))"
    }

    @ViewBuilder
    private var backgroundShape: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 18 : 14, style: .continuous)

        if compact {
            Color.clear
                .trayPanelSectionChrome(in: shape)
        } else {
            Color.clear
                .glassPanelSurface(
                    in: shape,
                    tone: .clear,
                    fallbackMaterial: .regularMaterial
                )
        }
    }

    private static func updatedAtText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return dayTimeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()
}

struct CompactLimitBarsView: View {
    let rows: [RateLimitDisplayRow]
    var dense = false

    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 6 : 8) {
            ForEach(Array(rows.prefix(2))) { row in
                CompactLimitBarRow(row: row, dense: dense)
            }
        }
    }
}

private struct CompactLimitBarRow: View {
    let row: RateLimitDisplayRow
    let dense: Bool

    var body: some View {
        HStack(spacing: dense ? 6 : 8) {
            Text(compactTitle)
                .font(dense ? .caption : .caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: dense ? 46 : 56, alignment: .leading)

            CompactLimitBar(progress: row.remainingProgressValue, tint: tint, height: dense ? 8 : 10)
                .frame(maxWidth: .infinity)

            Text("\(row.remainingPercent)%")
                .font(dense ? .caption.weight(.semibold) : .caption.weight(.bold))
                .monospacedDigit()
                .frame(width: dense ? 38 : 44, alignment: .trailing)
        }
    }

    private var compactTitle: String {
        switch row.title {
        case "5ч лимит":
            return "5ч"
        case "Недельный лимит":
            return "Неделя"
        case "1ч лимит":
            return "1ч"
        case "Суточный лимит":
            return "Сутки"
        default:
            return row.title.replacingOccurrences(of: " лимит", with: "")
        }
    }

    private var tint: Color {
        switch row.remainingPercent {
        case 0...9:
            return .red
        case 10...24:
            return .orange
        default:
            return .blue
        }
    }
}

private struct CompactLimitBar: View {
    let progress: Double
    let tint: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 4)
            let fillWidth = progress == 0 ? 0 : max(8, availableWidth * progress)

            ZStack(alignment: .leading) {
                MinimalProgressTrack()

                Capsule()
                    .fill(tint.gradient)
                    .padding(2)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: height)
    }
}
