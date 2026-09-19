//
//  VoiceBargeInRoutePolicy.swift
//  Conduit
//
//  A single, testable seam for deciding whether acoustic barge-in is safe
//  while Hermes is audibly speaking, so AVAudioSession route inspection
//  never scatters across controller and UI code.
//

import AVFAudio
import Foundation

/// Whether the microphone may stay live while the assistant's own TTS plays.
enum VoiceBargeInRoutePolicy: Equatable {
    /// The output is acoustically isolated from this device's microphone
    /// (wired headset, or a Bluetooth headset-profile pairing where capture
    /// and playback both travel the headset's own mic/speaker). The user can
    /// keep speaking over Hermes: live barge-in monitoring stays armed.
    case fullDuplex
    /// The output can feed this device's microphone (built-in speaker,
    /// built-in receiver, or a generic/external output with no clear
    /// headset pairing). Capture is suspended while Hermes speaks: the
    /// amplitude-based barge-in detector cannot tell the speaker's own TTS
    /// from user speech (device-reproduced feedback loop).
    case speakerSafeHalfDuplex

    /// Classifies a route from its port descriptions. Fail-safe: EVERY
    /// active output must be proven acoustically safe — one unsafe output
    /// (an AirPlay or room speaker alongside AirPods, say) vetoes the
    /// entire route into half duplex.
    static func resolve(
        outputs: [VoiceAudioRoutePort],
        inputs: [VoiceAudioRoutePort]
    ) -> VoiceBargeInRoutePolicy {
        guard !outputs.isEmpty else { return .speakerSafeHalfDuplex }
        // A Bluetooth headset-profile INPUT paired with the same accessory's
        // output is clear evidence of a usable headset microphone/output
        // pairing (AirPods, mono headsets): the voice session's output
        // travels the headset's own speaker. Name equality keeps two
        // different accessories (headset mic + room speaker) conservative,
        // and empty names never pair (two anonymous ports are not evidence).
        // Residual limitation: two distinct accessories reporting identical
        // names are indistinguishable at this seam and may pair —
        // AVAudioSession exposes no accessory UID to disambiguate them.
        let pairedHeadsetInputNames = Set(
            inputs
                .filter { $0.type == .bluetoothHFP && !$0.name.isEmpty }
                .map(\.name)
        )
        let everyOutputIsSafe = outputs.allSatisfy { output in
            switch output.type {
            case .headphones:
                // Wired headset/earphones: output sits in the user's ears,
                // away from the device microphone.
                return true
            case .bluetoothHFP, .bluetoothA2DP:
                return pairedHeadsetInputNames.contains(output.name)
            default:
                // Built-in speaker/receiver, AirPlay, USB, CarPlay, and
                // every other or unknown output can feed the microphone:
                // unsafe. (Unpaired Bluetooth outputs are rejected above.)
                return false
            }
        }
        return everyOutputIsSafe ? .fullDuplex : .speakerSafeHalfDuplex
    }

    /// Classifies the session's live route. MainActor-scoped because
    /// AVAudioSession is.
    @MainActor
    static func current() -> VoiceBargeInRoutePolicy {
        let route = AVAudioSession.sharedInstance().currentRoute
        return resolve(
            outputs: route.outputs.map { VoiceAudioRoutePort(type: $0.portType, name: $0.portName) },
            inputs: route.inputs.map { VoiceAudioRoutePort(type: $0.portType, name: $0.portName) }
        )
    }
}

/// The port facts the policy classifier needs, decoupled from
/// AVAudioSessionPortDescription (which cannot be constructed in tests).
/// `name` participates in Bluetooth pairing: a full-duplex classification
/// requires the headset-profile input and the output to belong to the same
/// named accessory.
struct VoiceAudioRoutePort: Equatable {
    var type: AVAudioSession.Port
    var name: String
}
