import SwiftUI
import LimitsCore
import LimitsShared

struct ProviderFilterPicker: View {
    @Binding var selection: AccountsSidebarFilter
    let catalog: ProviderCatalogSnapshot

    var body: some View {
        Picker(L10n.tr("filter.show_accounts"), selection: $selection) {
            ForEach(catalog.filterOptions, id: \.rawValue) { filter in
                Text(filter.displayTitle).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .tint(selection.tint)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L10n.tr("filter.show_accounts"))
    }
}

private extension AccountsSidebarFilter {
    var displayTitle: String {
        switch self {
        case .all: L10n.tr("filter.all")
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var tint: Color {
        switch self {
        case .all:
            return .secondary
        case .codex:
            return ProviderAccent.codex
        case .claude:
            return ProviderAccent.claude
        }
    }
}
