import Foundation
import os

enum Log {
    static let model = Logger(subsystem: subsystem, category: "model")
    static let peer = Logger(subsystem: subsystem, category: "peer")
    static let audio = Logger(subsystem: subsystem, category: "audio")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Totem"
}
