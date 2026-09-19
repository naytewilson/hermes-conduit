import AVFAudio
import XCTest
@testable import Conduit

final class VoiceBargeInRoutePolicyTests: XCTestCase {
    private func port(_ type: AVAudioSession.Port, _ name: String = "") -> VoiceAudioRoutePort {
        VoiceAudioRoutePort(type: type, name: name)
    }

    func testBuiltInSpeakerAndReceiverAreHalfDuplex() {
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.builtInSpeaker, "Speaker")],
                inputs: [port(.builtInMic, "Microphone")]
            ),
            .speakerSafeHalfDuplex
        )
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.builtInReceiver, "Receiver")],
                inputs: [port(.builtInMic, "Microphone")]
            ),
            .speakerSafeHalfDuplex
        )
    }

    func testWiredHeadphonesAreFullDuplexEvenWithBuiltInMic() {
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.headphones, "Wired Headphones")],
                inputs: [port(.builtInMic, "Microphone")]
            ),
            .fullDuplex
        )
    }

    func testBluetoothHeadsetProfilePairingIsFullDuplex() {
        // AirPods / HFP headsets during a voice session: capture and playback
        // both travel the headset's own mic and speaker.
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothHFP, "AirPods Pro")],
                inputs: [port(.bluetoothHFP, "AirPods Pro")]
            ),
            .fullDuplex
        )
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothA2DP, "AirPods Pro")],
                inputs: [port(.bluetoothHFP, "AirPods Pro")]
            ),
            .fullDuplex
        )
    }

    func testA2DPOnlyBluetoothOutputIsHalfDuplex() {
        // A Bluetooth speaker with no headset microphone: its output feeds
        // the built-in mic.
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothA2DP, "Boombox")],
                inputs: [port(.builtInMic, "Microphone")]
            ),
            .speakerSafeHalfDuplex
        )
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothA2DP, "Boombox")],
                inputs: []
            ),
            .speakerSafeHalfDuplex
        )
    }

    func testMismatchedBluetoothAccessoryNamesAreHalfDuplex() {
        // HFP input and A2DP output from DIFFERENT accessories (headset mic
        // selected while a room speaker renders) is exactly the feedback
        // geometry this policy exists to prevent: stay conservative.
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothA2DP, "Boombox")],
                inputs: [port(.bluetoothHFP, "Car Kit")]
            ),
            .speakerSafeHalfDuplex
        )
    }

    func testEmptyBluetoothNamesNeverPair() {
        // Two anonymous ports reporting empty names are not evidence of a
        // headset pairing.
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothA2DP, "")],
                inputs: [port(.bluetoothHFP, "")]
            ),
            .speakerSafeHalfDuplex
        )
    }

    func testHeadphonesPlusAirPlayIsHalfDuplex() {
        // Every output must be proven safe: an open AirPlay route alongside
        // wired headphones vetoes full duplex.
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.headphones, "Wired"), port(.airPlay, "Living Room")],
                inputs: [port(.builtInMic, "Microphone")]
            ),
            .speakerSafeHalfDuplex
        )
    }

    func testPairedAirPodsPlusUnrelatedA2DPRoomSpeakerIsHalfDuplex() {
        // AirPods' own HFP pairing is real, but the second (unpaired)
        // Bluetooth output is a room speaker whose audio feeds the mic.
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothHFP, "AirPods Pro"), port(.bluetoothA2DP, "Room Speaker")],
                inputs: [port(.bluetoothHFP, "AirPods Pro")]
            ),
            .speakerSafeHalfDuplex
        )
    }

    func testHeadsetProfileOutputWithoutHeadsetInputIsHalfDuplex() {
        // Ambiguous: HFP output routed, but capture still on the built-in
        // mic. Conservative classification wins.
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothHFP, "Headset")],
                inputs: [port(.builtInMic, "Microphone")]
            ),
            .speakerSafeHalfDuplex
        )
    }

    func testGenericAndExternalOutputsAreHalfDuplex() {
        let genericOutputs: [AVAudioSession.Port] = [.airPlay, .usbAudio, .carAudio]
        for output in genericOutputs {
            XCTAssertEqual(
                VoiceBargeInRoutePolicy.resolve(
                    outputs: [port(output, "External")],
                    inputs: [port(.builtInMic, "Microphone")]
                ),
                .speakerSafeHalfDuplex,
                "\(output.rawValue) output must be half duplex"
            )
        }
    }

    func testEmptyOrUnknownRoutesAreHalfDuplex() {
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(outputs: [], inputs: []),
            .speakerSafeHalfDuplex,
            "an unclassifiable route must never allow acoustic barge-in during playback"
        )
    }

    func testOpenSpeakerVetoesHeadsetInMixedOutputs() {
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.builtInSpeaker, "Speaker"), port(.headphones, "Wired")],
                inputs: [port(.builtInMic, "Microphone")]
            ),
            .speakerSafeHalfDuplex,
            "audio may be rendering to the open speaker, so mixed routes stay half duplex"
        )
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.builtInReceiver, "Receiver"), port(.bluetoothHFP, "AirPods Pro")],
                inputs: [port(.bluetoothHFP, "AirPods Pro")]
            ),
            .speakerSafeHalfDuplex
        )
    }
}
