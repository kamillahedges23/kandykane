import Foundation
import AVFoundation

// Runs inside the broadcast extension, which keeps running whichever app is
// on screen: sends frames to Claude, speaks answers, and records the session
// for the app to display.
final class BroadcastScanner: NSObject, AVSpeechSynthesizerDelegate {

    private let queue = DispatchQueue(label: "kandykane.scanner")
    private let client = ClaudeClient()
    private let synth = AVSpeechSynthesizer()

    // Everything below is only touched on `queue`.
    private var snapshot = SessionSnapshot()
    private var pending: Data?
    private var lastAnalysis = Date.distantPast
    private var lastQuestion = ""
    private var busy = false
    private var speaking = false
    private var retryScheduled = false
    private var stopped = false

    override init() {
        super.init()
        synth.delegate = self
        SessionState.write(snapshot)
        configureAudio()
    }

    // Called with every frame the extension captures. Only the newest one is
    // kept, so a question that appears while an answer is being spoken is
    // still picked up afterwards.
    func offer(_ jpeg: Data) {
        queue.async {
            self.pending = jpeg
            self.tryAnalyze()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.pending = nil
        }
        DispatchQueue.main.async {
            self.synth.stopSpeaking(at: .immediate)
        }
    }

    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            queue.async {
                self.update { $0.error = "Couldn't start audio: \(error.localizedDescription)" }
            }
        }
    }

    private func tryAnalyze() {
        guard !stopped, !busy, !speaking, pending != nil else { return }

        // Don't pay to scan KandyKane's own screen.
        if FrameBridge.isAppVisible {
            pending = nil
            return
        }

        let wait = KandyKaneConfig.analysisInterval - Date().timeIntervalSince(lastAnalysis)
        if wait > 0 {
            if !retryScheduled {
                retryScheduled = true
                queue.asyncAfter(deadline: .now() + wait) {
                    self.retryScheduled = false
                    self.tryAnalyze()
                }
            }
            return
        }

        guard let frame = pending else { return }
        pending = nil
        busy = true
        lastAnalysis = Date()
        update {
            $0.status = "Scanning"
            $0.error = nil
        }

        let previous = lastQuestion
        Task {
            let result: Result<ClaudeResponse, Error>
            do {
                result = .success(try await client.analyze(frame: frame, previousQuestion: previous))
            } catch {
                result = .failure(error)
            }
            queue.async { self.finish(result) }
        }
    }

    private func finish(_ result: Result<ClaudeResponse, Error>) {
        busy = false
        guard !stopped else { return }

        switch result {
        case .success(let response)
            where response.hasQuestion && !response.answer.isEmpty && response.question != lastQuestion:
            lastQuestion = response.question
            speaking = true
            update {
                $0.answers.append(.init(question: response.question, answer: response.answer))
                $0.status = "Speaking"
            }
            DispatchQueue.main.async { self.speak(response.answer) }
        case .success:
            update { $0.status = "Watching" }
            tryAnalyze()
        case .failure(let error):
            update {
                $0.status = "Watching"
                $0.error = error.localizedDescription
            }
            tryAnalyze()
        }
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utterance)
    }

    private func finishedSpeaking() {
        queue.async {
            self.speaking = false
            guard !self.stopped else { return }
            self.update { $0.status = "Watching" }
            self.tryAnalyze()
        }
    }

    private func update(_ change: (inout SessionSnapshot) -> Void) {
        change(&snapshot)
        SessionState.write(snapshot)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishedSpeaking()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishedSpeaking()
    }
}
