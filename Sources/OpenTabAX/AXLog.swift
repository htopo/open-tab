import Foundation
import os

/// Logging for the accessibility layer.
///
/// Separate from `OpenTabCore.Log` because the dependency runs the other way:
/// OpenTabCore depends on OpenTabAX, so this module cannot reach back for it.
/// The subsystem string is shared, so both still show up under one predicate.
enum AXLog {
    static let subsystem = "io.github.htopo.opentab"

    static let ax = Logger(subsystem: subsystem, category: "accessibility")
    static let symbols = Logger(subsystem: subsystem, category: "symbols")
}
