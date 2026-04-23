import SwiftUI

struct CurrentCLIOverviewCard: View {
    let overview: AppModel.CurrentCLIOverview
    let source: AppModel.CurrentCLIState.Source
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

                CLIStateBadge(source: source)
            }

            if let limits = overview.limits {
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

            if isBusy, let busyMessage {
                Text(busyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var noteColor: Color {
        switch source {
        case .stored:
            return .secondary
        case .external:
            return .orange
        case .missing:
            return .secondary
        case .unreadable:
            return .red
        }
    }
}
