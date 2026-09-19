import Foundation

/// A silent stub until the sound-design pass produces the six assets.
enum SoundPlayer {
    enum Sound: String {
        case signOn = "sign-on"
        case signOff = "sign-off"
        case buddyIn = "buddy-in"
        case buddyOut = "buddy-out"
        case messageReceived = "message-received"
        case messageSent = "message-sent"
    }

    static func play(_ sound: Sound) {
        // TODO: AVAudioPlayer with bundled assets, .ambient category on iOS
        // so the silent switch is respected.
    }
}
