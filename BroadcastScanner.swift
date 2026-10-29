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

    // Only touched on the main thread, where speech is started.
    private var lastUtterance: AVSpeechUtterance?

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
                // If the quick check fails, still let the full call look.
                let isNew = (try? await client.hasNewQuestion(frame: frame, previousQuestion: previous)) ?? true
                if isNew {
                    result = .success(try await client.analyze(frame: frame, previousQuestion: previous))
                } else {
                    result = .success(.none)
                }
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
        case .success(let response) where !response.adjust.isEmpty:
            speaking = true
            update { $0.status = response.adjust }
            DispatchQueue.main.async { self.speak(response.adjust) }
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

    // Read slowly and evenly, one line at a time with a short pause between
    // lines, then say the answer a second time so it can be checked.
    private func speak(_ text: String) {
        var lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = lines.last, last.lowercased().hasPrefix("the answer") {
            lines.append("One more time, the" + last.dropFirst("The".count))
        }
        lastUtterance = nil
        for (index, line) in lines.enumerated() {
            let utterance = AVSpeechUtterance(string: line)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.6
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            if index > 0 { utterance.preUtteranceDelay = 0.6 }
            lastUtterance = utterance
            synth.speak(utterance)
        }
        if lastUtterance == nil { finishedSpeaking() }
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
        DispatchQueue.main.async {
            guard utterance === self.lastUtterance else { return }
            self.finishedSpeaking()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishedSpeaking()
    }
}
