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
        .tint(ProviderAccent.codex)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L10n.tr("filter.show_accounts"))
    }
}
