import SwiftUI
import ReplayKit

@main
struct KandyKaneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {

    @StateObject private var engine = SessionMonitor()
    @Environment(\.scenePhase) private var scenePhase

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
        .onAppear {
            engine.appActive = scenePhase == .active
            engine.start()
        }
        .onDisappear { engine.stop() }
        .onChange(of: scenePhase) { phase in
            engine.appActive = phase == .active
        }
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
    let id: Int
    let question: String
    let answer: String
}

// Shows what the broadcast extension is doing. The extension does the
// scanning and speaking, because iOS suspends this app while another app is
// on screen.
@MainActor
final class SessionMonitor: ObservableObject {

    @Published var status = "Waiting for a screen share"
    @Published var errorMessage: String?
    @Published var log: [LogEntry] = []
    @Published var preview: UIImage?
    @Published var isLive = false

    // While KandyKane is on screen the extension would only see this app, so
    // it pauses scanning.
    var appActive = false {
        didSet { FrameBridge.setAppVisible(appActive) }
    }

    private var timer: Timer?
    private var lastFrameStamp: TimeInterval = 0

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        if appActive {
            FrameBridge.setAppVisible(true)
        }

        let live = FrameBridge.isLive
        if live != isLive {
            isLive = live
            if !live {
                preview = nil
                lastFrameStamp = 0
                status = "Waiting for a screen share"
                errorMessage = nil
            }
        }
        guard live else { return }

        // Capture the timestamp before reading, so a frame written in between
        // is picked up on the next refresh instead of being marked as seen.
        let frameStamp = FrameBridge.latestTimestamp
        if frameStamp > lastFrameStamp, let frame = FrameBridge.readLatest() {
            lastFrameStamp = frameStamp
            if let image = UIImage(data: frame) {
                preview = image
            }
        }

        guard let session = SessionState.read() else { return }
        status = session.status
        errorMessage = session.error
        if session.answers.count != log.count {
            log = session.answers.enumerated().reversed().map { index, entry in
                LogEntry(id: index, question: entry.question, answer: entry.answer)
            }
        }
    }
}
