import SwiftUI

struct SettingsView: View {
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all
    @AppStorage("autoCheck") private var autoCheck = true
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        NavigationStack {
            Form {
                Section("Aanbiedingen") {
                    Picker("Taal", selection: $languageFilter) {
                        ForEach(LanguageFilter.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Toggle("Alerts per staat automatisch controleren", isOn: $autoCheck)
                } footer: {
                    Text("Gebeurt als de app open staat: bij het starten en op de Mac elke 30 minuten. Vraagt Cardmarket een beveiligingscontrole, dan krijg je een melding om die zelf aan te tikken.")
                }
                Section("Gegevens") {
                    if let d = catalog.lastUpdated {
                        LabeledContent("Prijzen bijgewerkt", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Kaarten", value: catalog.items.count.formatted())
                }
                Section("Bronnen") {
                    Text("Prijzen: openbare Cardmarket price guide. Afbeeldingen en setnamen: TCGdex. Aanbiedingen worden uit de Cardmarket-pagina gelezen, wat tegen hun voorwaarden kan zijn.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Instellingen")
        }
    }
}
