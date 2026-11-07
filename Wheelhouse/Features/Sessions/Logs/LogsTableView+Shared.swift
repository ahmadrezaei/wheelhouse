import SwiftUI
import WheelhouseKit

/// Everything the table needs to render; value type so SwiftUI diffing stays cheap.
struct LogsDisplaySettings: Equatable {
    var wrap = true
    var timestamps = false
    var fontSize: CGFloat = 12
    var query = ""
    var useRegex = false
    var currentLineID: Int?
}
