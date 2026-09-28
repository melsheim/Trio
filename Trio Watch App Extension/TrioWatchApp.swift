import SwiftUI
import UserNotifications
import ClockKit

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchNotificationHandler.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            }
        }
    }
}


final class BrianGlucoseComplicationController: NSObject, CLKComplicationDataSource {
    private let staleAfter: TimeInterval = 7 * 60

    private func snapshot(at now: Date = Date()) -> (glucose: String, arrow: String?) {
        let defaults = UserDefaults.standard
        let timestamp = defaults.double(forKey: "BrianClockComplication.timestamp")
        guard timestamp > 0 else { return ("---", nil) }

        let sampleDate = Date(timeIntervalSince1970: timestamp)
        guard now.timeIntervalSince(sampleDate) <= staleAfter else {
            return ("---", nil)
        }

        let glucose = defaults.string(forKey: "BrianClockComplication.glucose") ?? "---"
        let trend = defaults.string(forKey: "BrianClockComplication.trend")
        return (glucose, Self.arrow(for: trend))
    }

    private static func arrow(for trend: String?) -> String? {
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

    func getCurrentTimelineEntry(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void
    ) {
        let current = snapshot()
        let text = current.arrow.map { "\(current.glucose)\($0)" } ?? current.glucose

        let template: CLKComplicationTemplate?
        switch complication.family {
        case .graphicCircular:
            template = CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
                gaugeProvider: CLKSimpleGaugeProvider(style: .fill, gaugeColor: .white, fillFraction: 1),
                bottomTextProvider: CLKSimpleTextProvider(text: current.glucose),
                centerTextProvider: CLKSimpleTextProvider(text: current.arrow ?? "")
            )
        case .graphicCorner:
            template = CLKComplicationTemplateGraphicCornerStackText(
                innerTextProvider: CLKSimpleTextProvider(text: current.arrow ?? ""),
                outerTextProvider: CLKSimpleTextProvider(text: current.glucose)
            )
        case .circularSmall:
            template = CLKComplicationTemplateCircularSmallSimpleText(
                textProvider: CLKSimpleTextProvider(text: text)
            )
        case .utilitarianSmall, .utilitarianSmallFlat:
            template = CLKComplicationTemplateUtilitarianSmallFlat(
                textProvider: CLKSimpleTextProvider(text: text)
            )
        default:
            template = nil
        }

        guard let template else {
            handler(nil)
            return
        }
        handler(CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template))
    }

    func getTimelineEntries(
        for complication: CLKComplication,
        after date: Date,
        limit: Int,
        withHandler handler: @escaping ([CLKComplicationTimelineEntry]?) -> Void
    ) {
        let defaults = UserDefaults.standard
        let timestamp = defaults.double(forKey: "BrianClockComplication.timestamp")
        guard timestamp > 0 else {
            handler(nil)
            return
        }

        let staleDate = Date(timeIntervalSince1970: timestamp).addingTimeInterval(staleAfter)
        guard staleDate > date else {
            handler(nil)
            return
        }

        let staleTemplate: CLKComplicationTemplate?
        switch complication.family {
        case .graphicCircular:
            staleTemplate = CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
                gaugeProvider: CLKSimpleGaugeProvider(style: .fill, gaugeColor: .gray, fillFraction: 1),
                bottomTextProvider: CLKSimpleTextProvider(text: "---"),
                centerTextProvider: CLKSimpleTextProvider(text: "")
            )
        case .graphicCorner:
            staleTemplate = CLKComplicationTemplateGraphicCornerStackText(
                innerTextProvider: CLKSimpleTextProvider(text: ""),
                outerTextProvider: CLKSimpleTextProvider(text: "---")
            )
        case .circularSmall:
            staleTemplate = CLKComplicationTemplateCircularSmallSimpleText(
                textProvider: CLKSimpleTextProvider(text: "---")
            )
        case .utilitarianSmall, .utilitarianSmallFlat:
            staleTemplate = CLKComplicationTemplateUtilitarianSmallFlat(
                textProvider: CLKSimpleTextProvider(text: "---")
            )
        default:
            staleTemplate = nil
        }

        guard let staleTemplate else {
            handler(nil)
            return
        }
        handler([CLKComplicationTimelineEntry(date: staleDate, complicationTemplate: staleTemplate)])
    }

    func getLocalizableSampleTemplate(
        for complication: CLKComplication,
        withHandler handler: @escaping (CLKComplicationTemplate?) -> Void
    ) {
        switch complication.family {
        case .graphicCircular:
            handler(
                CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
                    gaugeProvider: CLKSimpleGaugeProvider(style: .fill, gaugeColor: .white, fillFraction: 1),
                    bottomTextProvider: CLKSimpleTextProvider(text: "123"),
                    centerTextProvider: CLKSimpleTextProvider(text: "→")
                )
            )
        case .graphicCorner:
            handler(
                CLKComplicationTemplateGraphicCornerStackText(
                    innerTextProvider: CLKSimpleTextProvider(text: "→"),
                    outerTextProvider: CLKSimpleTextProvider(text: "123")
                )
            )
        case .circularSmall:
            handler(CLKComplicationTemplateCircularSmallSimpleText(textProvider: CLKSimpleTextProvider(text: "123→")))
        case .utilitarianSmall, .utilitarianSmallFlat:
            handler(CLKComplicationTemplateUtilitarianSmallFlat(textProvider: CLKSimpleTextProvider(text: "123→")))
        default:
            handler(nil)
        }
    }
}
