import SwiftUI
import WheelhouseDesktop
import WheelhouseUI

/// The capability flags of the running edition, as environment values. Views read these instead of asking `Edition` directly, so a
/// test can host a view with either setting.
private struct ChartRoomCapabilitiesKey: EnvironmentKey { static var defaultValue: ChartRoomCapabilities { .current } }
private struct SurveyCapabilitiesKey: EnvironmentKey { static var defaultValue: SurveyCapabilities { .current } }
private struct TidesCapabilitiesKey: EnvironmentKey { static var defaultValue: TidesCapabilities { .current } }

extension EnvironmentValues {
    var chartRoomCapabilities: ChartRoomCapabilities {
        get { self[ChartRoomCapabilitiesKey.self] }
        set { self[ChartRoomCapabilitiesKey.self] = newValue }
    }

    var surveyCapabilities: SurveyCapabilities {
        get { self[SurveyCapabilitiesKey.self] }
        set { self[SurveyCapabilitiesKey.self] = newValue }
    }

    var tidesCapabilities: TidesCapabilities {
        get { self[TidesCapabilitiesKey.self] }
        set { self[TidesCapabilitiesKey.self] = newValue }
    }
}

/// The one-line note that stands where a hidden flow was: what is missing and a link to the editions page.
struct OpenSourceEditionNote: View {
    let message: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(message).foregroundStyle(.secondary)
            Link("Learn More", destination: EditionNotice.learnMore)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("edition-note")
    }
}
