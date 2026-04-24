import SwiftUI

struct ProviderFilterPicker: View {
    @Binding var selection: AccountsSidebarFilter

    var body: some View {
        Picker(L10n.tr("filter.show_accounts"), selection: $selection) {
            Text(L10n.tr("filter.all")).tag(AccountsSidebarFilter.all)
            Text("Codex").tag(AccountsSidebarFilter.codex)
            Text("Claude").tag(AccountsSidebarFilter.claude)
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
