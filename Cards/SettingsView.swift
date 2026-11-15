import SwiftUI

struct SettingsView: View {
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all
    @AppStorage("autoCheck") private var autoCheck = true
    @Environment(CatalogStore.self) private var catalog
    @Environment(AppSettings.self) private var settings
    @Environment(CardmarketSession.self) private var session
    @State private var imageBytes: Int64 = 0
    @State private var showLogin = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: session.isLoggedIn ? "Ingelogd\(session.username.map { " (\($0))" } ?? "")" : "Niet ingelogd")
                    Button(session.isLoggedIn ? "Account beheren" : "Inloggen bij Cardmarket") { showLogin = true }
                    NavigationLink("Mijn aanbod beoordelen (experimenteel)") { MyStockView() }
                } header: { Text("Cardmarket-account") } footer: {
                    Text("Je logt zelf in op Cardmarket in een webweergave; de app ziet je wachtwoord niet. De sessie blijft bewaard zolang Cardmarket dat toestaat. Cardmarket biedt geen API meer aan, dus de app leest pagina's uit zoals een browser dat doet.")
                }

                Section("Aanbiedingen") {
                    Picker("Taal", selection: $languageFilter) {
                        ForEach(LanguageFilter.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Picker("Mijn land", selection: $settings.homeCountry) {
                        ForEach(AppSettings.countryChoices, id: \.self) { Text("\(AppSettings.flag($0)) \($0)").tag($0) }
                    }
                    Toggle("Verzending meetellen in de dealscore", isOn: $settings.includeShipping)
                    money("Binnenland, brief", $settings.shipDomestic)
                    money("Binnenland, aangetekend (boven €25)", $settings.shipDomesticTracked)
                    money("EU, brief", $settings.shipEU)
                    money("EU, aangetekend (boven €25)", $settings.shipEUTracked)
                    money("Buiten de EU", $settings.shipWorld)
                } header: { Text("Verzendkosten (schatting)") } footer: {
                    Text("Startwaarden zijn schattingen: Cardmarket berekent de echte kosten per verkoper, land en gewicht. Boven €25 is aangetekend verzenden verplicht. Pas de bedragen aan naar wat jij betaalt.")
                }

                Section {
                    LabeledContent("Commissie (%)") {
                        TextField("5", value: $settings.sellerFeePercent, format: .number).multilineTextAlignment(.trailing)
                    }
                    Toggle("Waarden verbergen (privacymodus)", isOn: $settings.hideValues)
                } header: { Text("Verkopen en privacy") } footer: {
                    Text("De commissie is een schatting (vaak 5% voor particuliere verkopers) en geldt over de artikelwaarde. Controleer je eigen tarief bij Cardmarket.")
                }

                Section {
                    Toggle("Alerts per staat automatisch controleren", isOn: $autoCheck)
                } header: { Text("Meldingen") } footer: {
                    Text("""
                    Trend-alerts: bij het starten van de app (en op iPhone af en toe op de achtergrond, wanneer iOS dat toestaat) vergelijkt de app de Cardmarket-trendprijs met je doel.
                    Alerts per staat en koopjes: de app laadt de aanbiedingen van je gevolgde kaarten. Dat kan alleen terwijl de app open staat: bij het starten, op de Mac elke 30 minuten, of met Controleren in de watchlist. Vraagt Cardmarket een beveiligingscontrole, dan krijg je een melding om die zelf aan te tikken.
                    De meldingen zijn lokaal. Er is geen server die je telefoon wekt als de app dicht is.
                    """)
                }

                Section("Gegevens") {
                    if let d = catalog.lastUpdated {
                        LabeledContent("Prijzen bijgewerkt", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Kaarten", value: catalog.items.count.formatted())
                    LabeledContent("Opgeslagen plaatjes", value: ByteCountFormatter.string(fromByteCount: imageBytes, countStyle: .file))
                    Button("Plaatjescache wissen", role: .destructive) {
                        Task { await ImageStore.shared.clear(); imageBytes = await ImageStore.shared.diskBytes() }
                    }
                }
                Section("Bronnen") {
                    Text("Prijzen: openbare Cardmarket price guide. Afbeeldingen, setnamen en TCGplayer-prijzen: TCGdex. Wisselkoers: ECB via Frankfurter. Aanbiedingen worden uit Cardmarket-pagina's gelezen, wat tegen hun voorwaarden kan zijn.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Instellingen")
            .task { imageBytes = await ImageStore.shared.diskBytes() }
            .sheet(isPresented: $showLogin) { LoginSheet() }
        }
    }

    private func money(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("0", value: value, format: .currency(code: "EUR")).multilineTextAlignment(.trailing)
        }
    }
}
