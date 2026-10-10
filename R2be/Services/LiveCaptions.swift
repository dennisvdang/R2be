import AVFoundation
import MediaToolbox
import Observation
import Speech
import SwiftUI
import Translation

/// Live subtitles for the playing video. Its audio is tapped as it plays (playback is untouched),
/// transcribed on the phone by Speech, and from iOS 18 translated into the phone's language by the
/// Translation framework. The player view drives translation through `TranslatedCaptions`.
/// Recognition is on-device only: audio never leaves the phone, and a language without an offline
/// speech model shows a message instead of falling back to Apple's servers.
@Observable
@MainActor
final class LiveCaptions {
    var isOn = UserDefaults.standard.bool(forKey: "captionsOn") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "captionsOn")
            if isOn { requestPermissionThenStart() } else { stop() }
        }
    }

    /// The language spoken in the video; nil takes it from the audio track's language tag.
    var spokenOverride: Locale.Language? {
        didSet { translated = ""; if isOn { startRecognition() } }
    }
    private(set) var detectedLanguage: Locale.Language?
    var spokenLanguage: Locale.Language? { spokenOverride ?? detectedLanguage }
    let targetLanguage = Locale.current.language

    /// The newest stretch of speech, and its translation once one is ready.
    private(set) var original = ""
    private(set) var translated = ""
    private(set) var status: String?

    var needsTranslation: Bool {
        guard let spoken = spokenLanguage else { return false }
        return spoken.languageCode != targetLanguage.languageCode
    }

    /// What the subtitle shows. When translating, only translated text is shown, so the line never
    /// flips between languages; before iOS 18 it falls back to the original.
    var line: String {
        if #available(iOS 18.0, *), needsTranslation { return translated }
        return original
    }

    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var rollover: Task<Void, Never>?
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private let feed = AudioFeed()

    // MARK: Video

    func attach(to item: AVPlayerItem) {
        self.item = item
        detectedLanguage = nil
        original = ""
        translated = ""
        guard isOn else { return }
        Task { await install(on: item) }
    }

    func detach() {
        item = nil
        stopRecognition()
        original = ""
        translated = ""
    }

    private func install(on item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else {
            status = "This video has no audio to subtitle."
            return
        }
        let code = (try? await track.load(.languageCode)) ?? nil
        guard item === self.item, isOn else { return }
        detectedLanguage = code.flatMap(Self.language(fromTrackCode:))
        if item.audioMix == nil, let tap = AudioTap.make(feed: feed) {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
        startRecognition()
    }

    // MARK: Speech

    private func requestPermissionThenStart() {
        SFSpeechRecognizer.requestAuthorization { auth in
            Task { @MainActor [weak self] in
                guard let self, self.isOn else { return }
                guard auth == .authorized else {
                    self.status = "Allow Speech Recognition for R2be in iPhone Settings to see subtitles."
                    return
                }
                if let item = self.item { await self.install(on: item) }
            }
        }
    }

    private func startRecognition() {
        stopRecognition()
        let language = spokenLanguage ?? targetLanguage
        guard isOn, let locale = Self.speechLocale(for: language),
              let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            status = "Subtitles aren't available for \(Self.name(of: language))."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            status = "\(Self.name(of: language)) needs its offline speech model. Add it in Settings → General → Keyboard → Dictation Languages."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request
        feed.set(request)
        status = nil

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result.map { Self.subtitleTail($0.bestTranscription.formattedString) }
            let finished = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let text, !text.isEmpty { self.show(text) }
                guard finished else { return }

                // A finished task hands over to the next one; a short pause stops an error from spinning.
                try? await Task.sleep(for: .seconds(text == nil ? 1 : 0))
                if self.request === request, self.isOn { self.startRecognition() }
            }
        }

        // Recognition sessions time out after about a minute, so roll over to a fresh one before then.
        rollover = Task { [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard !Task.isCancelled else { return }
            self?.request?.endAudio()
        }
    }

    private func stopRecognition() {
        rollover?.cancel()
        feed.set(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func stop() {
        stopRecognition()
        original = ""
        translated = ""
        status = nil
    }

    private func show(_ text: String) {
        original = text
        if needsTranslation { pending = text }
    }

    // MARK: Translation

    @available(iOS 18.0, *)
    var translationConfiguration: TranslationSession.Configuration? {
        guard isOn, needsTranslation, let spoken = spokenLanguage else { return nil }
        return TranslationSession.Configuration(source: spoken, target: targetLanguage)
    }

    /// Runs for as long as the player shows subtitles, translating the newest line as it changes.
    @available(iOS 18.0, *)
    func serve(_ session: TranslationSession) async {
        while !Task.isCancelled {
            guard let text = pending else {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            pending = nil
            do {
                translated = try await session.translate(text).targetText
            } catch {
                status = "Can't translate \(Self.name(of: spokenLanguage ?? targetLanguage)) yet."
            }
        }
    }

    // MARK: Helpers

    static let commonLanguages: [Locale.Language] =
        ["en", "ja", "ko", "zh", "es", "fr", "de", "it", "pt", "ru", "hi", "ar"].map { Locale.Language(identifier: $0) }

    nonisolated static func name(of language: Locale.Language) -> String {
        language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? "this language"
    }

    /// Track tags are ISO 639-2 ("jpn"); "und" means untagged.
    nonisolated static func language(fromTrackCode code: String) -> Locale.Language? {
        guard !code.isEmpty, code != "und" else { return nil }
        let alpha2 = Locale.LanguageCode(code).identifier(.alpha2) ?? code
        return Locale.Language(identifier: alpha2)
    }

    /// A recognizer locale for `language`, preferring the phone's region ("ja" → "ja-JP").
    nonisolated static func speechLocale(for language: Locale.Language) -> Locale? {
        let matches = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode == language.languageCode }
        return matches.first { $0.region == Locale.current.region }
            ?? matches.min { $0.identifier < $1.identifier }
    }

    /// The part of a running transcript worth showing: the current sentence, at most `maxLength`
    /// characters, cut at a word where there are spaces.
    nonisolated static func subtitleTail(_ text: String, maxLength: Int = 90) -> String {
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        if let cut = body.dropLast().lastIndex(where: { enders.contains($0) }) {
            body = body[body.index(after: cut)...]
        }
        if body.count > maxLength {
            body = body.suffix(maxLength)
            if let space = body.firstIndex(of: " ") { body = body[body.index(after: space)...] }
        }
        return body.trimmingCharacters(in: .whitespaces)
    }
}

/// Gives the player view's `.translationTask` to `LiveCaptions` on iOS 18 and later.
struct TranslatedCaptions: ViewModifier {
    let captions: LiveCaptions

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.translationTask(captions.translationConfiguration) { session in await captions.serve(session) }
        } else {
            content
        }
    }
}

// MARK: - Audio tap

/// Hands audio from the real-time tap thread to whichever speech request is current.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { self.request = request } }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request }?.append(buffer) }
}

/// An audio-mix tap that copies the first channel of the playing audio into an `AudioFeed`.
enum AudioTap {
    static func make(feed: AudioFeed) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(TapContext(feed: feed)).toOpaque()

        let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
            storageOut.pointee = clientInfo
        }
        let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
            Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        }
        let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
            Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
        }
        let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
            guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
            Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                .forward(bufferList, frames: framesOut.pointee)
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: context,
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: nil, process: tapProcess)
        var tap: Unmanaged<MTAudioProcessingTap>?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged<TapContext>.fromOpaque(context).release()
            return nil
        }
        return tap.takeRetainedValue()
    }
}

private final class TapContext {
    let feed: AudioFeed
    private var mono: AVAudioFormat?
    private var isFloatPlanar = false

    init(feed: AudioFeed) { self.feed = feed }

    func prepare(_ format: AudioStreamBasicDescription) {
        isFloatPlanar = format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate, channels: 1, interleaved: false)
    }

    func forward(_ list: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard isFloatPlanar, frames > 0, let mono,
              let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)),
              let source = UnsafeMutableAudioBufferListPointer(list).first?.mData,
              let target = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        target.update(from: source.assumingMemoryBound(to: Float.self), count: Int(frames))
        feed.append(buffer)
    }
}
