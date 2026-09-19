import AVFAudio

struct VoiceAudioSessionConfiguration: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let outputSampleRate: Double
    let outputChannelCount: AVAudioChannelCount

    static let capture = Self(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetoothHFP, .defaultToSpeaker],
        outputSampleRate: 16_000,
        outputChannelCount: 1
    )

    /// Output-only policy for standalone speech (Read Aloud, TTS provider
    /// test): `.playback` never claims the microphone, and `.mixWithOthers` +
    /// `.duckOthers` let already-playing media (Spotify, Audible) continue at
    /// reduced volume while Conduit speaks instead of being interrupted.
    /// Ducking ends the moment the session deactivates, so standalone speech
    /// stops affecting other media immediately when it finishes. Deliberately
    /// not `.voiceChat`: these flows never record, and a record category
    /// keeps other media suppressed even while idle.
    /// The sample-rate fields below belong to the capture policy and are
    /// unused by playback; the values mirror the gateway speech stream.
    static let standalonePlayback = Self(
        category: .playback,
        mode: .default,
        options: [.mixWithOthers, .duckOthers],
        outputSampleRate: 24_000,
        outputChannelCount: 1
    )
}
