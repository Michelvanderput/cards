import SwiftUI

struct CollectionView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(CollectionStore.self) private var collection
    @State private var editing: CollectionEntry?
    @State private var query = ""

    private var filtered: [CollectionEntry] {
        let list = collection.entries.sorted {
            (collection.unitValue($0, catalog: catalog) ?? 0) * Double($0.quantity) >
            (collection.unitValue($1, catalog: catalog) ?? 0) * Double($1.quantity)
        }
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !collection.entries.isEmpty {
                    summary.listRowInsets(.init()).listRowBackground(Color.clear)
                }
                ForEach(filtered) { e in
                    if let item = catalog.byID[e.productID] {
                        Button { editing = e } label: { row(e, item) }.buttonStyle(.plain)
                            .swipeActions { Button("Verwijder", role: .destructive) { collection.remove(e.id) } }
                    }
                }
            }
            .overlay {
                if collection.entries.isEmpty {
                    ContentUnavailableView("Je collectie is leeg", systemImage: "rectangle.stack",
                        description: Text("Open een kaart en kies Collectie om hem toe te voegen, met staat en je eigen prijs."))
                }
            }
            .searchable(text: $query, prompt: "Zoek in je collectie")
            .navigationTitle("Collectie")
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
            .sheet(item: $editing) { entry in
                if let item = catalog.byID[entry.productID] { AddToCollectionSheet(item: item, existing: entry) }
            }
        }
    }

    private var summary: some View {
        let value = collection.totalValue(catalog: catalog)
        let paid = collection.totalPaid
        return VStack(alignment: .leading, spacing: 10) {
            Text("Totale waarde").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Text(euro(value)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            HStack(spacing: 18) {
                stat("Kaarten", "\(collection.totalCards)")
                if paid > 0 {
                    stat("Betaald", euro(paid))
                    let diff = value - paid
                    stat(diff >= 0 ? "Winst" : "Verlies", euro(abs(diff)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.gradient, in: .rect(cornerRadius: 18))
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
        }
    }

    private func row(_ e: CollectionEntry, _ item: CardItem) -> some View {
        HStack(spacing: 12) {
            CardImage(item: item).frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(2)
                HStack(spacing: 6) {
                    ConditionBadge(condition: e.condition)
                    if e.quantity > 1 { Text("\(e.quantity)×").font(.caption.weight(.semibold)) }
                    if let set = catalog.setName(for: item) { Text(set).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                let unit = collection.unitValue(e, catalog: catalog)
                Text(euro(unit.map { $0 * Double(e.quantity) })).monospacedDigit()
                Text(e.myPrice == nil ? "schatting" : "jouw prijs").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

/// Kaart aan je collectie toevoegen of een bestaande regel aanpassen.
struct AddToCollectionSheet: View {
    let item: CardItem
    var existing: CollectionEntry?
    @Environment(CollectionStore.self) private var collection
    @Environment(MarketStore.self) private var market
    @Environment(\.dismiss) private var dismiss
    @State private var condition: Condition = .nm
    @State private var quantity = 1
    @State private var paid: Double?
    @State private var myPrice: Double?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CardImage(item: item).frame(width: 60)
                        VStack(alignment: .leading) {
                            Text(item.name).font(.headline)
                            Text("Trend \(euro(item.mainPrice))").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Kaart") {
                    Picker("Staat", selection: $condition) {
                        ForEach(Condition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Aantal: \(quantity)", value: $quantity, in: 1...999)
                }
                Section {
                    TextField("Betaald per kaart (EUR)", value: $paid, format: .number)
                    TextField("Jouw prijs per kaart (EUR)", value: $myPrice, format: .number)
                    ForEach(suggestions, id: \.label) { s in
                        Button("\(s.label): \(euro(s.price))") { myPrice = s.price }
                    }
                } header: {
                    Text("Prijs")
                } footer: {
                    Text("Jouw prijs bepaal je zelf. Laat je hem leeg, dan telt de app de Cardmarket-trend (alle staten) als schatting.")
                }
                Section("Notitie") { TextField("Bijvoorbeeld: gesigneerd, 1e editie", text: $note) }
                if let existing {
                    Section { Button("Verwijder uit collectie", role: .destructive) { collection.remove(existing.id); dismiss() } }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Aan collectie" : "Bewerken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Bewaar", action: save) }
            }
            .onAppear {
                if let e = existing { condition = e.condition; quantity = e.quantity; paid = e.paidPrice; myPrice = e.myPrice; note = e.note }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private var suggestions: [(label: String, price: Double)] {
        var out: [(String, Double)] = []
        if let t = item.mainPrice { out.append(("Cardmarket-trend", t)) }
        if let s = market.stats(item.id, minCondition: condition) ?? (condition == .nm ? market.stats(item.id, minCondition: .nm) : nil) {
            out.append(("Mediaan \(condition.rawValue)+ aanbiedingen", s.median))
        }
        return out
    }

    private func save() {
        if var e = existing {
            e.condition = condition; e.quantity = quantity; e.paidPrice = paid; e.myPrice = myPrice; e.note = note
            collection.update(e)
        } else {
            collection.add(CollectionEntry(productID: item.id, name: item.name, condition: condition,
                                           quantity: quantity, paidPrice: paid, myPrice: myPrice, note: note))
        }
        dismiss()
    }
}
