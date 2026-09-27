import SwiftUI
import WidgetKit

private enum BrianGlucoseSnapshot {
    static let glucoseKey = "BrianComplication.glucose"
    static let trendKey = "BrianComplication.trend"
    static let timestampKey = "BrianComplication.timestamp"
    static let staleAfter: TimeInterval = 7 * 60

    static func load(at now: Date = Date()) -> (glucose: String, arrow: String?, timestamp: Date?) {
        // The complication extension cannot share the Watch app's App Group
        // with the current provisioning setup. Keep the stale-safe UI in place;
        // a subsequent transport experiment can replace this storage adapter.
        let defaults = UserDefaults.standard

        let timestampValue = defaults.double(forKey: timestampKey)
        guard timestampValue > 0 else { return ("---", nil, nil) }

        let timestamp = Date(timeIntervalSince1970: timestampValue)
        guard now.timeIntervalSince(timestamp) <= staleAfter else {
            return ("---", nil, timestamp)
        }

        let glucose = defaults.string(forKey: glucoseKey) ?? "---"
        let trend = defaults.string(forKey: trendKey)
        return (glucose, trendArrow(for: trend), timestamp)
    }

    static func trendArrow(for trend: String?) -> String? {
        switch trend {
        case "DoubleUp": return "↑↑"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown": return "↓"
        case "DoubleDown": return "↓↓"
        default: return nil
        }
    }
}

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let glucose: String
    let arrow: String?
    let sampleDate: Date?
}

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(date: Date(), glucose: "123", arrow: "→", sampleDate: Date())
    }

    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let now = Date()
        let current = makeEntry(at: now)
        var entries = [current]

        // Schedule an explicit stale-state entry. A fresh glucose update asks
        // WidgetKit to replace this timeline before the stale entry is reached.
        if let sampleDate = current.sampleDate {
            let staleDate = sampleDate.addingTimeInterval(BrianGlucoseSnapshot.staleAfter)
            if staleDate > now {
                entries.append(
                    TrioWatchComplicationEntry(
                        date: staleDate,
                        glucose: "---",
                        arrow: nil,
                        sampleDate: sampleDate
                    )
                )
            }
        }

        completion(Timeline(entries: entries, policy: .never))
    }

    private func makeEntry(at date: Date = Date()) -> TrioWatchComplicationEntry {
        let snapshot = BrianGlucoseSnapshot.load(at: date)
        return TrioWatchComplicationEntry(
            date: date,
            glucose: snapshot.glucose,
            arrow: snapshot.arrow,
            sampleDate: snapshot.timestamp
        )
    }
}

struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        #if os(watchOS)
        case .accessoryCorner:
            TrioAccessoryCornerView(entry: entry)
        #endif
        default:
            TrioAccessoryCircularView(entry: entry)
        }
    }
}

#if os(watchOS)
struct TrioAccessoryCornerView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        Text(entry.glucose)
            .font(.headline)
            .fontWeight(.bold)
            .minimumScaleFactor(0.55)
            .widgetCurvesContent()
            .widgetLabel {
                Text(entry.arrow ?? "")
            }
            .widgetBackground(backgroundView: Color.clear)
    }
}
#endif

struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        VStack(spacing: -2) {
            Text(entry.glucose)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            if let arrow = entry.arrow {
                Text(arrow)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .widgetAccentable()
        .widgetBackground(backgroundView: Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Glucose \(entry.glucose) \(entry.arrow ?? "")")
    }
}

@main struct TrioWatchComplication: Widget {
    let kind = "TrioWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
                .widgetURL(URL(string: "Trio://"))
        }
        .configurationDisplayName("Trio Glucose")
        .description("Large current glucose and trend. Stale readings are hidden.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        return [.accessoryCorner, .accessoryCircular]
        #else
        return [.accessoryCircular]
        #endif
    }
}

extension View {
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}
