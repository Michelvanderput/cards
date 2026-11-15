import SwiftUI
import UserNotifications

struct AlertSheet: View {
    let item: CardItem
    @Environment(WatchStore.self) private var watch
    @Environment(MarketStore.self) private var market
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var direction: AlertDirection = .below
    @State private var condition: Condition? = nil
    @State private var target: Double?
    @State private var dealAlert = false
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var saving = false
    @State private var resultMessage: String?

    /// Een alert heeft een doelprijs nodig, of koopjes-meldingen aan.
    private var isValid: Bool { (target ?? 0) > 0 || dealAlert }

    var body: some View {
        NavigationStack {
            Form {
                if status == .denied {
                    Section {
                        Label("Meldingen staan uit voor Cards. Zonder meldingen merk je niets van een alert.", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Button("Open instellingen") { NotificationSupport.openSystemSettings() }
                    }
                }
                Section {
                    Picker("Staat", selection: $condition) {
                        Text("Alle (trendprijs)").tag(Condition?.none)
                        ForEach(Condition.filterChoices) { Text($0.rawValue + " of beter").tag(Condition?.some($0)) }
                    }
                    if condition == nil {
                        Picker("Melden wanneer prijs", selection: $direction) {
                            ForEach(AlertDirection.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    PriceField(title: "Doelprijs in EUR", value: $target)
                } header: { Text("Doelprijs") } footer: {
                    if let t = target, t <= 0 { Text("Vul een bedrag hoger dan 0 in.").foregroundStyle(.red) }
                    else if condition == nil && target == nil { Text("Typ bijvoorbeeld 12,50.") }
                }
                if let sug = DealAnalyzer.suggestion(item: item, minCondition: condition, market: market), condition != nil || direction == .below {
                    Section("Voorstel") {
                        Button("Gebruik \(euro(sug.price))") { target = sug.price }
                        Text(sug.basis).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Meld koopjes (dealscore 80+)", isOn: $dealAlert)
                } footer: {
                    Text("De app beoordeelt dan elke keer dat hij de aanbiedingen controleert of er een uitzonderlijk goede aanbieding is, ook zonder doelprijs.")
                }
                Section {
                    Text("Nu (trend, alle staten): \(euro(item.mainPrice))").foregroundStyle(.secondary)
                    if condition != nil || dealAlert {
                        Text("Alerts per staat en koopjes kijken naar de aanbiedingen op Cardmarket. Dat gebeurt zolang de app open staat, of als je Watchlist controleren kiest.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let existing = watch.entry(item.id), existing.alertSummary != nil {
                    Section {
                        Button("Alert verwijderen", role: .destructive) { watch.clearAlert(item.id); dismiss() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Prijsalert")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bewaar") { Task { await save() } }.disabled(!isValid || saving)
                }
            }
            .alert("Alert bewaard", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { dismiss() } })) {
                Button("OK") { dismiss() }
            } message: { Text(resultMessage ?? "") }
            .task {
                status = await WatchStore.authorizationStatus()
                if let e = watch.entry(item.id) {
                    direction = e.direction; target = e.target; condition = e.minCondition; dealAlert = e.dealAlert ?? false
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 440)
        #endif
    }

    private func save() async {
        saving = true
        defer { saving = false }
        // Meldingen toestaan (de eerste keer vraagt het systeem erom).
        if status == .notDetermined { _ = await WatchStore.requestPermission() }
        status = await WatchStore.authorizationStatus()
        watch.setAlert(item.id, target: (target ?? 0) > 0 ? target : nil, direction: direction, minCondition: condition, dealAlert: dealAlert)

        var lines: [String] = []
        // Een trend-alert controleren we meteen, zodat je niet hoeft te wachten tot de app opnieuw start.
        if condition == nil, (target ?? 0) > 0 {
            let sent = await watch.evaluate(catalog: catalog)
            lines.append(sent > 0 ? "Je doelprijs is al gehaald: er is een melding verstuurd." : "Je krijgt een melding zodra de trendprijs je doelprijs bereikt.")
        } else {
            lines.append("Zodra de app de aanbiedingen controleert, krijg je een melding als je alert gehaald wordt.")
        }
        if !NotificationSupport.isAllowed(status) { lines.append("Let op: meldingen staan uit voor Cards, dus je ziet geen banner.") }
        resultMessage = lines.joined(separator: "\n")
    }
}
