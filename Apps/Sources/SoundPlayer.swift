import Foundation

/// Six required assets: sign-on, sign-off, buddy-in, buddy-out, message-received,
/// message-sent (spec §6). Sound design is a dedicated pass (spec §9 step 7);
/// until assets exist this is a silent stub. Must respect the silent switch on iOS.
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
        // TODO: AVAudioPlayer with bundled assets, .ambient category on iOS.
    }
}
