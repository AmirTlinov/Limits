import SwiftUI

struct ProviderFilterPicker: View {
    @Binding var selection: AccountsSidebarFilter

    var body: some View {
        Picker("Показать аккаунты", selection: $selection) {
            Text("Все").tag(AccountsSidebarFilter.all)
            Text("Codex").tag(AccountsSidebarFilter.codex)
            Text("Claude").tag(AccountsSidebarFilter.claude)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .tint(ProviderAccent.codex)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Показать аккаунты")
    }
}
