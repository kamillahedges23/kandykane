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
    @State private var apiKey: String = KandyKaneConfig.sharedDefaults?
        .string(forKey: KandyKaneConfig.apiKeyDefaultsKey) ?? ""
    @State private var showKey = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {

                Text("KandyKane")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 40)

                Text("Share your screen and it reads questions aloud.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                keyField

                BroadcastButton()
                    .frame(height: 64)
                    .padding(.horizontal, 24)

                statusPanel

                Spacer()

                if !engine.log.isEmpty {
                    answerLog
                }
            }
        }
        .onChange(of: apiKey) { _, newValue in
            KandyKaneConfig.sharedDefaults?.set(
                newValue,
                forKey: KandyKaneConfig.apiKeyDefaultsKey
            )
        }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }

    private var keyField: some View {
        HStack {
            Group {
                if showKey {
                    TextField("API key", text: $apiKey)
                } else {
                    SecureField("API key", text: $apiKey)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 16, design: .monospaced))
            .foregroundStyle(.white)

            Button {
                showKey.toggle()
            } label: {
                Image(systemName: showKey ? "eye.slash" : "eye")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private var statusPanel: some View {
        VStack(spacing: 8) {
            Text(engine.status)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))

            if !engine.currentAnswer.isEmpty {
                Text(engine.currentAnswer)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button("Hear it again") {
                    engine.speak(engine.currentAnswer)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
            }

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
        picker.preferredExtension = "kandykane.broadcast"
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
final class ScanEngine: ObservableObject {

    @Published var status = "Waiting for a screen share"
    @Published var currentAnswer = ""
    @Published var errorMessage: String?
    @Published var log: [LogEntry] = []

    private let client = ClaudeClient()
    private let synth = AVSpeechSynthesizer()
    private var timer: Timer?
    private var lastSeen: TimeInterval = 0
    private var lastQuestion = ""
    private var busy = false

    func start() {
        configureAudio()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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
        guard !busy else { return }
        guard FrameBridge.hasNewFrame(since: lastSeen) else { return }
        guard let frame = FrameBridge.readLatest() else { return }

        busy = true
        lastSeen = FrameBridge.latestTimestamp
        status = "Reading the screen"
        errorMessage = nil

        do {
            let result = try await client.analyze(frame: frame)

            if result.hasQuestion, result.question != lastQuestion {
                lastQuestion = result.question
                currentAnswer = result.answer
                log.insert(
                    LogEntry(question: result.question, answer: result.answer),
                    at: 0
                )
                speak(result.answer)
                status = "Answered"
            } else {
                status = "Watching for questions"
            }
        } catch {
            errorMessage = error.localizedDescription
            status = "Watching for questions"
        }

        busy = false
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)
    }
}
