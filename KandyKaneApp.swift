import SwiftUI
import ReplayKit
import AVFoundation

@main
struct KandyKaneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {

    @StateObject private var engine = ScanEngine()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {

                Text("KandyKane")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, engine.isLive ? 16 : 40)

                if !engine.isLive {
                    Text("Share your screen and it reads questions aloud.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                BroadcastButton()
                    .frame(height: 64)
                    .padding(.horizontal, 24)

                if let preview = engine.preview {
                    screenPreview(preview)
                }

                statusPanel

                if engine.preview == nil {
                    Spacer()
                }

                if !engine.log.isEmpty {
                    answerLog
                }
            }
        }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }

    // The most recent captured frame, like a shared screen on a video call.
    private func screenPreview(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
    }

    private var statusPanel: some View {
        VStack(spacing: 8) {
            Text(engine.status)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))

            if let error = engine.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var answerLog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(engine.log) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.question)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(entry.answer)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .frame(maxHeight: 260)
        .background(Color.white.opacity(0.05))
    }
}

struct BroadcastButton: UIViewRepresentable {

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 64)
        )
        picker.preferredExtension = "kandykane.com.broadcast"
        picker.showsMicrophoneButton = false

        for case let button as UIButton in picker.subviews {
            button.imageView?.tintColor = .white
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct LogEntry: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

@MainActor
final class ScanEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published var status = "Waiting for a screen share"
    @Published var errorMessage: String?
    @Published var log: [LogEntry] = []
    @Published var preview: UIImage?
    @Published var isLive = false

    private let client = ClaudeClient()
    private let synth = AVSpeechSynthesizer()
    private var timer: Timer?
    private var lastFrameStamp: TimeInterval = 0
    private var lastAnalysis = Date.distantPast
    private var lastQuestion = ""
    private var busy = false
    private var speaking = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func start() {
        configureAudio()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func configureAudio() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func tick() async {
        let live = FrameBridge.isLive
        if live != isLive {
            isLive = live
            if live {
                // A new broadcast starts a new session.
                log = []
                lastQuestion = ""
                errorMessage = nil
                status = "Watching"
            } else {
                preview = nil
                lastFrameStamp = 0
                status = "Waiting for a screen share"
            }
        }
        guard live else { return }

        // Capture the timestamp before reading, so a frame written in between
        // is picked up on the next tick instead of being marked as seen.
        let frameStamp = FrameBridge.latestTimestamp
        guard frameStamp > lastFrameStamp, let frame = FrameBridge.readLatest() else { return }
        lastFrameStamp = frameStamp
        if let image = UIImage(data: frame) {
            preview = image
        }

        // Let an answer finish before looking for the next question.
        guard !busy, !speaking,
              Date().timeIntervalSince(lastAnalysis) >= KandyKaneConfig.analysisInterval else {
            return
        }
        await analyze(frame)
    }

    private func analyze(_ frame: Data) async {
        busy = true
        defer { busy = false }
        lastAnalysis = Date()
        status = "Scanning"
        errorMessage = nil

        do {
            let result = try await client.analyze(frame: frame, previousQuestion: lastQuestion)
            guard isLive else { return }

            if result.hasQuestion, !result.answer.isEmpty, result.question != lastQuestion {
                lastQuestion = result.question
                log.insert(
                    LogEntry(question: result.question, answer: result.answer),
                    at: 0
                )
                speak(result.answer)
            } else {
                status = "Watching"
            }
        } catch {
            errorMessage = error.localizedDescription
            status = isLive ? "Watching" : "Waiting for a screen share"
        }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speaking = true
        status = "Speaking"

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)
    }

    private func finishedSpeaking() {
        speaking = false
        status = isLive ? "Watching" : "Waiting for a screen share"
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
}
