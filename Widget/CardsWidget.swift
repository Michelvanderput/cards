import WidgetKit
import SwiftUI

struct SummaryEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary?
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry { SummaryEntry(date: .now, summary: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(SummaryEntry(date: .now, summary: WidgetSummary.load() ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let entry = SummaryEntry(date: .now, summary: WidgetSummary.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct CollectionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SummaryEntry

    private func euro(_ v: Double) -> String { v.formatted(.currency(code: "EUR").precision(.fractionLength(0))) }

    var body: some View {
        if let s = entry.summary {
            VStack(alignment: .leading, spacing: 4) {
                Label("Collectie", systemImage: "rectangle.stack").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Text(s.hideValues ? "€ ••••" : euro(s.total))
                    .font(.system(size: family == .systemSmall ? 30 : 38, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).foregroundStyle(.white)
                Text("\(s.cardCount) kaarten").font(.caption).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                if let name = s.moverName, let change = s.moverChange {
                    HStack(spacing: 4) {
                        Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        Text(name).lineLimit(1)
                        Text(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.title2)
                Text("Open Cards om je collectie te tonen").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        }
    }
}

struct CollectionWidget: Widget {
    let kind = "CollectionValue"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummaryProvider()) { entry in
            CollectionWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.36, green: 0.31, blue: 0.92), Color(red: 0.62, green: 0.30, blue: 0.90)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("Collectiewaarde")
        .description("De totale waarde van je collectie en de grootste stijger van de week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CardsWidgetBundle: WidgetBundle {
    var body: some Widget { CollectionWidget() }
}
