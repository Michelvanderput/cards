import SwiftUI

struct BindersView: View {
    @Environment(BinderStore.self) private var binders
    @Environment(CatalogStore.self) private var catalog
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    ForEach(binders.binders) { b in
                        NavigationLink(value: b.id) { BinderCover(binder: b) }.buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .overlay {
                if binders.binders.isEmpty {
                    ContentUnavailableView {
                        Label("Nog geen binders", systemImage: "books.vertical")
                    } description: {
                        Text("Stel je eigen binder samen en zet er kaarten in zoals in een echte.")
                    } actions: {
                        Button("Nieuwe binder") { showNew = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Binders")
            .navigationDestination(for: UUID.self) { BinderView(binderID: $0) }
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: { Label("Nieuwe binder", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showNew) { BinderEditSheet() }
        }
    }
}

struct BinderCover: View {
    let binder: Binder
    @Environment(BinderStore.self) private var binders
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        let color = Theme.binderColors[binder.colorIndex % Theme.binderColors.count]
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle().fill(.black.opacity(0.18)).frame(width: 14).frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(.rect(topLeadingRadius: 14, bottomLeadingRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(binder.name).font(.headline).foregroundStyle(.white).lineLimit(2)
                Text("\(binder.filled) van \(binder.slots.count) kaarten")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                Text(euro(binders.value(binder, catalog: catalog))).font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.leading, 28).padding(.trailing, 12).padding(.bottom, 12)
        }
        .aspectRatio(0.8, contentMode: .fit)
        .shadow(color: color.opacity(0.35), radius: 8, y: 4)
    }
}

struct BinderEditSheet: View {
    var existing: Binder?
    @Environment(BinderStore.self) private var binders
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorIndex = 0
    @State private var columns = 3
    @State private var rows = 3
    @State private var pages = 4

    var body: some View {
        NavigationStack {
            Form {
                TextField("Naam", text: $name)
                Section("Kleur") {
                    HStack {
                        ForEach(Theme.binderColors.indices, id: \.self) { i in
                            Circle().fill(Theme.binderColors[i]).frame(width: 30, height: 30)
                                .overlay { if i == colorIndex { Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold()) } }
                                .onTapGesture { colorIndex = i }
                        }
                    }
                }
                if existing == nil {
                    Section("Indeling") {
                        Stepper("Kolommen: \(columns)", value: $columns, in: 2...4)
                        Stepper("Rijen: \(rows)", value: $rows, in: 2...4)
                        Stepper("Pagina's: \(pages)", value: $pages, in: 1...50)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Nieuwe binder" : "Binder bewerken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bewaar") {
                        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Mijn binder" : name
                        if let existing { binders.rename(existing.id, name: n, colorIndex: colorIndex) }
                        else { _ = binders.add(name: n, colorIndex: colorIndex, columns: columns, rows: rows, pages: pages) }
                        dismiss()
                    }
                }
            }
            .onAppear { if let e = existing { name = e.name; colorIndex = e.colorIndex } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
    }
}

struct BinderView: View {
    let binderID: UUID
    @Environment(BinderStore.self) private var binders
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var pickingSlot: Int?
    @State private var showEdit = false
    @State private var confirmDelete = false

    var body: some View {
        if let binder = binders.binder(binderID) {
            let color = Theme.binderColors[binder.colorIndex % Theme.binderColors.count]
            VStack(spacing: 12) {
                pageGrid(binder, color: color)
                    .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                        if v.translation.width < -40 { goTo(page + 1, binder) }
                        else if v.translation.width > 40 { goTo(page - 1, binder) }
                    })
                pager(binder)
            }
            .padding()
            .navigationTitle(binder.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Bewerken", systemImage: "pencil") { showEdit = true }
                        Button("Pagina toevoegen", systemImage: "plus.square.on.square") {
                            binders.addPage(binderID); page = binder.pages
                        }
                        Button("Verwijder binder", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Label("Opties", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(item: $pickingSlot) { slot in
                BinderCardPicker { productID in binders.setSlot(binderID, index: slot, productID: productID) }
            }
            .sheet(isPresented: $showEdit) { BinderEditSheet(existing: binder) }
            .confirmationDialog("Binder verwijderen?", isPresented: $confirmDelete) {
                Button("Verwijder", role: .destructive) { binders.remove(binderID); dismiss() }
            } message: { Text("De kaarten in je collectie blijven bewaard.") }
        } else {
            ContentUnavailableView("Binder niet gevonden", systemImage: "books.vertical")
        }
    }

    private func goTo(_ p: Int, _ binder: Binder) {
        withAnimation(.snappy) { page = min(max(p, 0), binder.pages - 1) }
    }

    private func pager(_ binder: Binder) -> some View {
        HStack(spacing: 20) {
            Button { goTo(page - 1, binder) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
            VStack(spacing: 1) {
                Text("Pagina \(page + 1) van \(binder.pages)").font(.subheadline.weight(.medium))
                Text("\(binder.filled)/\(binder.slots.count) kaarten · \(euro(binders.value(binder, catalog: catalog)))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { goTo(page + 1, binder) } label: { Image(systemName: "chevron.right") }.disabled(page >= binder.pages - 1)
        }
        .buttonStyle(.bordered)
    }

    private func pageGrid(_ binder: Binder, color: Color) -> some View {
        let start = page * binder.slotsPerPage
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: binder.columns), spacing: 8) {
            ForEach(0..<binder.slotsPerPage, id: \.self) { offset in
                slot(binder, index: start + offset)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.5), lineWidth: 2))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func slot(_ binder: Binder, index: Int) -> some View {
        Group {
            if index < binder.slots.count, let pid = binder.slots[index], let item = catalog.byID[pid] {
                NavigationLink(value: item) {
                    CardImage(item: item)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                }
                .buttonStyle(.plain)
                .draggable(String(index))
                .contextMenu {
                    Button("Vervangen", systemImage: "arrow.triangle.2.circlepath") { pickingSlot = index }
                    Button("Verwijder uit binder", systemImage: "minus.circle", role: .destructive) {
                        binders.setSlot(binderID, index: index, productID: nil)
                    }
                }
            } else {
                Button { pickingSlot = index } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .aspectRatio(Theme.cardRatio, contentMode: .fit)
                        .overlay { Image(systemName: "plus").foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(Int.init) else { return false }
            binders.swap(binderID, from, index)
            return true
        }
    }
}

extension Int: @retroactive Identifiable { public var id: Int { self } }

/// Kies een kaart voor een binder-vakje: uit je collectie of via zoeken.
struct BinderCardPicker: View {
    let onPick: (Int) -> Void
    @Environment(CatalogStore.self) private var catalog
    @Environment(CollectionStore.self) private var collection
    @Environment(\.dismiss) private var dismiss
    @State private var fromCollection = true
    @State private var query = ""

    private var items: [CardItem] {
        if fromCollection {
            var seen = Set<Int>()
            let all = collection.entries.compactMap { e -> CardItem? in
                guard seen.insert(e.productID).inserted else { return nil }
                return catalog.byID[e.productID]
            }
            return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return catalog.search(query, limit: 60)
    }

    var body: some View {
        NavigationStack {
            List(items) { item in
                Button { onPick(item.id); dismiss() } label: { CardRow(item: item) }.buttonStyle(.plain)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(fromCollection ? "Geen kaarten in je collectie" : "Zoek een kaart",
                                           systemImage: fromCollection ? "rectangle.stack" : "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "Zoek op naam")
            .safeAreaInset(edge: .top) {
                Picker("Bron", selection: $fromCollection) {
                    Text("Uit collectie").tag(true)
                    Text("Alle kaarten").tag(false)
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6)
            }
            .navigationTitle("Kies een kaart")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Sluit") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}
