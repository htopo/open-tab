import Foundation
import os

/// Centralised logging.
///
/// Categories map to the module that emits them, so `log stream --predicate
/// 'subsystem == "io.github.htopo.opentab"'` gives a readable trace of a switch
/// without needing a debugger attached — which matters because most of OpenTab's
/// interesting behaviour happens while another app is frontmost.
public enum Log {
    public static let subsystem = "io.github.htopo.opentab"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let registry = Logger(subsystem: subsystem, category: "registry")
    public static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    public static let input = Logger(subsystem: subsystem, category: "input")
    public static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let overlay = Logger(subsystem: subsystem, category: "overlay")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let updates = Logger(subsystem: subsystem, category: "updates")
}

/// Measures how long a block takes and logs it above a threshold.
///
/// Used on the paths with a hard latency budget — the overlay has to be on screen
/// in well under 100 ms — so regressions surface in the log rather than as a vague
/// "feels sluggish".
@discardableResult
public func measure<T>(_ label: String,
                       threshold: TimeInterval = 0.016,
                       logger: Logger = Log.app,
                       _ body: () throws -> T) rethrows -> T {
    let start = DispatchTime.now()
    defer {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        if elapsed > threshold {
            logger.notice("\(label, privacy: .public) took \(elapsed * 1000, format: .fixed(precision: 1))ms")
        } else {
            logger.debug("\(label, privacy: .public) took \(elapsed * 1000, format: .fixed(precision: 1))ms")
        }
    }
    return try body()
}
