import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .defaultValue
    @AppStorage("autoCheck") private var autoCheck = true
    @AppStorage("groupVariants") private var groupVariants = true
    @AppStorage("hideGraded") private var hideGraded = true
    @Environment(CatalogStore.self) private var catalog
    @Environment(AppSettings.self) private var settings
    @Environment(CardmarketSession.self) private var session
    @State private var imageBytes: Int64 = 0
    @State private var showLogin = false
    @State private var sync = CloudSync.shared
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var testSent = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Toggle("Synchroniseer via iCloud", isOn: Binding(get: { sync.isEnabled }, set: { sync.isEnabled = $0 }))
                    LabeledContent("Status", value: syncStatus)
                    if sync.isEnabled { Button("Nu synchroniseren") { Task { await sync.syncAll() } } }
                } header: { Text("iCloud") } footer: {
                    Text("Collectie, watchlist, binders en prijsgeschiedenis worden gelijkgehouden tussen je Mac en iPhone (zelfde Apple ID, iCloud Drive aan). Wijzigingen op beide apparaten tegelijk worden samengevoegd. Prijzen en plaatjes worden per apparaat opgehaald.")
                }

                Section {
                    LabeledContent("Status", value: session.isLoggedIn ? "Ingelogd\(session.username.map { " (\($0))" } ?? "")" : "Niet ingelogd")
                    Button(session.isLoggedIn ? "Account beheren" : "Inloggen bij Cardmarket") { showLogin = true }
                    NavigationLink("Mijn aanbod beoordelen (experimenteel)") { MyStockView() }
                } header: { Text("Cardmarket-account") } footer: {
                    Text("Je logt zelf in op Cardmarket in een webweergave; de app ziet je wachtwoord niet. De sessie blijft bewaard zolang Cardmarket dat toestaat. Cardmarket biedt geen API meer aan, dus de app leest pagina's uit zoals een browser dat doet.")
                }

                Section {
                    Toggle("Uitvoeringen van een kaart groeperen", isOn: $groupVariants)
                } header: { Text("Weergave") } footer: {
                    Text("Aan: één tegel per kaart, met een label als \"2 uitvoeringen\". Uit: elk Cardmarket-product apart, zoals normaal, reverse holo of een ander patroon.")
                }

                Section {
                    Picker("Taal", selection: $languageFilter) {
                        ForEach(LanguageFilter.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Gegradeerde kaarten verbergen", isOn: $hideGraded)
                } header: { Text("Aanbiedingen") } footer: {
                    Text("Met \"Alleen Engels\" ziet de app alleen Engelse aanbiedingen. Gegradeerde kaarten (PSA, BGS, CGC...) staan op Cardmarket als gewone staat met het cijfer in de opmerking; de app verbergt ze zodat ze de markt voor losse kaarten niet vertekenen. Beide gelden ook voor dealscores, marktstatistieken, alerts en bundelen.")
                }

                Section {
                    Picker("Mijn land", selection: $settings.homeCountry) {
                        ForEach(AppSettings.countryChoices, id: \.self) { Text("\(AppSettings.flag($0)) \($0)").tag($0) }
                    }
                    Toggle("Verzending meetellen in de dealscore", isOn: $settings.includeShipping)
                    if settings.homeCountry == ShippingTable.shared?.destination {
                        NavigationLink("Verzendkosten per land (officieel)") { ShippingCountriesView() }
                    } else {
                        money("Binnenland, brief", $settings.shipDomestic)
                        money("Binnenland, aangetekend (boven €25)", $settings.shipDomesticTracked)
                        money("EU, brief", $settings.shipEU)
                        money("EU, aangetekend (boven €25)", $settings.shipEUTracked)
                        money("Buiten de EU", $settings.shipWorld)
                    }
                } header: { Text("Verzendkosten") } footer: {
                    if settings.homeCountry == ShippingTable.shared?.destination {
                        Text("Voor Nederland gebruikt de app de officiële Cardmarket-tarieven per land van herkomst, op basis van het aantal kaarten en de waarde. Boven €25 is aangetekend verzenden verplicht.")
                    } else {
                        Text("Voor andere landen dan Nederland zijn dit schattingen die je zelf aanpast: Cardmarket berekent de echte kosten per verkoper, land en gewicht. Boven €25 is aangetekend verzenden verplicht.")
                    }
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
                    LabeledContent("Meldingen") {
                        Text(NotificationSupport.describe(notifStatus)).foregroundStyle(NotificationSupport.isAllowed(notifStatus) ? .green : .orange)
                    }
                    if notifStatus == .notDetermined {
                        Button("Meldingen toestaan") { Task { _ = await WatchStore.requestPermission(); notifStatus = await WatchStore.authorizationStatus() } }
                    }
                    if notifStatus == .denied { Button("Open instellingen") { NotificationSupport.openSystemSettings() } }
                    Button(testSent ? "Testmelding verstuurd" : "Stuur testmelding") {
                        Task {
                            if notifStatus == .notDetermined { _ = await WatchStore.requestPermission() }
                            await WatchStore.notify(title: "Testmelding", body: "Als je dit ziet, werken meldingen van Cards.")
                            notifStatus = await WatchStore.authorizationStatus()
                            testSent = true
                        }
                    }
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
            .task {
                imageBytes = await ImageStore.shared.diskBytes()
                notifStatus = await WatchStore.authorizationStatus()
            }
            .sheet(isPresented: $showLogin) { LoginSheet() }
        }
    }

    private var syncStatus: String {
        switch sync.status {
        case .off: "Uit"
        case .unavailable: "iCloud niet beschikbaar (log in bij iCloud en zet iCloud Drive aan)"
        case .syncing: "Bezig…"
        case .upToDate(let d): "Bijgewerkt \(d.formatted(.relative(presentation: .named)))"
        case .failed(let m): "Fout: \(m)"
        }
    }

    private func money(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("0", value: value, format: .currency(code: "EUR")).multilineTextAlignment(.trailing)
        }
    }
}
