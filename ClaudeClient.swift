import Foundation

struct ClaudeResponse {
    let hasQuestion: Bool
    let question: String
    let answer: String
    // A spoken instruction for moving or steadying the camera when a question
    // is only partly readable; empty otherwise.
    let adjust: String

    static let none = ClaudeResponse(hasQuestion: false, question: "", answer: "", adjust: "")
}

enum ClaudeError: LocalizedError {
    case missingKey
    case badResponse(Int, String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "This build has no API key. Check the ANTHROPIC_API_KEY secret."
        case .badResponse(let code, let message):
            return "The API returned status \(code)." + (message.map { " \($0)" } ?? "")
        case .decodingFailed:
            return "Could not read the response."
        }
    }
}

actor ClaudeClient {

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-opus-5-5"

    private let systemPrompt = """
    You're the brain of a hands-free helper. Each request is a screenshot of \
    the user's phone screen. Decide whether it shows a question, problem, or \
    exercise they'd want answered, and if so, answer it for them.

    Your answer is read aloud slowly while the user listens and writes it \
    down. Say it the way a person would say it out loud to a friend who's \
    writing it down: short, plain, natural. No symbols or formatting. Say \
    math in words, for example "x squared plus 3 x". Say every fraction as \
    the top "over" the bottom, for example "1 over 10" and "10 over x to the \
    11", never "one tenth" or "half". Use commas to split a long answer into \
    pieces, for example "1 over 10 to the x, times log of 1 over 10, minus \
    10 over x to the 11". Never say "the quantity", "open parenthesis", \
    "end of exponent", or anything else a person wouldn't say.

    - End with one line that names the problem and then gives exactly the \
    final answer the user would write and box, nothing more. Use the \
    problem's number and part as shown on screen: "The answer to problem 7 \
    is", "The answer to problem 7 part b is", or "The answer to part b is" \
    if there's a part but no number. Only if there's no number or part on \
    screen, say "The answer is". If the answer includes a left side, like \
    "dy dx equals" or "x equals", say it; if the answer is just an \
    expression or a number, say only that. Say this line only once.
    - Before that line, add work lines only when the problem needs shown \
    steps, like solving an equation. One short step per line, only what to \
    write, no explaining words like "so", "because", "next", or "we get". \
    Never repeat or rewrite the problem as a step. Derivatives, integrals, \
    limits, and simplifying usually need no steps. If no steps are needed, \
    the answer line is the whole answer.
    - If the question has several parts (a, b, c, and so on), answer only \
    one part: part a for a new question, or the part right after the \
    previous one you were told about, and never mention the other parts.
    - For multiple choice, the answer is the option's letter and its text.

    Set hasQuestion to false and leave question and answer empty when:
    - there's no question on screen,
    - the screen shows this app itself (a black screen titled KandyKane with \
    a preview and a list of past answers), or
    - it's the same question as the previous one you were told about and \
    it has no parts left to answer.

    The screen is often a camera view of a paper or another screen. If you \
    can see there's a question but can't read all of it, don't answer. \
    Instead set hasQuestion to false, leave question and answer empty, and \
    put one short spoken instruction in adjust:
    - "Hold the camera still, it's blurry" if it's too blurry to read,
    - "Move the camera up", "down", "left", or "right" if the question is \
    cut off at that edge of the image (cut off at the top means move up),
    - "Move the camera closer" if the text is too small to read, or "Move \
    the camera back" if the question doesn't fit in the image.
    Leave adjust empty in every other case, including when there's no \
    question at all.

    In question, restate the question in a few words and add the part you \
    answered, for example "derivative of sine of x, part b".
    """

    private let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "hasQuestion": ["type": "boolean"],
            "question": ["type": "string"],
            "answer": ["type": "string"],
            "adjust": ["type": "string"]
        ],
        "required": ["hasQuestion", "question", "answer", "adjust"],
        "additionalProperties": false
    ]

    // A quick, cheap look at each screenshot so the slower answering call
    // only runs when there's something new to answer.
    private let quickModel = "claude-haiku-5-5"

    private let quickPrompt = """
    Each request is a screenshot of a phone screen, often a camera view of \
    a paper or another screen. Set newQuestion to true if it shows a \
    question, problem, or exercise that hasn't been answered yet, even if \
    it's blurry or cut off. That includes a later part (b, c, and so on) of \
    the previous question when the previous answer covered an earlier part. \
    Set it to false if there's no question, if it's the same question and \
    part as the previous one with no parts left, or if the screen is a \
    black screen titled KandyKane. If you're unsure, set it to true.
    """

    private let quickSchema: [String: Any] = [
        "type": "object",
        "properties": ["newQuestion": ["type": "boolean"]],
        "required": ["newQuestion"],
        "additionalProperties": false
    ]

    // Returns false only when the screen clearly has nothing new to answer.
    func hasNewQuestion(frame jpegData: Data, previousQuestion: String) async throws -> Bool {
        let body: [String: Any] = [
            "model": quickModel,
            "max_tokens": 200,
            // Thinking off and low effort keep this check fast.
            "thinking": ["type": "disabled"],
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": quickSchema]
            ],
            "system": quickPrompt,
            "messages": [message(frame: jpegData, previousQuestion: previousQuestion)]
        ]

        let data = try await send(body, beta: nil)
        // Leave it to the main call when the quick one declines.
        guard let parsed = try parseJSON(data) else { return true }
        return parsed["newQuestion"] as? Bool ?? true
    }

    func analyze(frame jpegData: Data, previousQuestion: String) async throws -> ClaudeResponse {
        let body: [String: Any] = [
            "model": model,
            // Thinking is always on for this model and counts toward
            // max_tokens, so leave headroom for it.
            "max_tokens": 8000,
            "output_config": [
                // Medium keeps math answers reliable without slowing every scan.
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema]
            ],
            "fallbacks": "default",
            "system": systemPrompt,
            "messages": [message(frame: jpegData, previousQuestion: previousQuestion)]
        ]

        let data = try await send(body, beta: "server-side-fallback-2026-07-01")
        // A declined screenshot is treated like one without a question.
        guard let parsed = try parseJSON(data) else { return .none }

        return ClaudeResponse(
            hasQuestion: parsed["hasQuestion"] as? Bool ?? false,
            question: parsed["question"] as? String ?? "",
            answer: parsed["answer"] as? String ?? "",
            adjust: parsed["adjust"] as? String ?? ""
        )
    }

    private func message(frame jpegData: Data, previousQuestion: String) -> [String: Any] {
        let previous = previousQuestion.isEmpty
            ? "No question has been answered yet."
            : "The previous question was: \(previousQuestion)"
        return [
            "role": "user",
            "content": [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": jpegData.base64EncodedString()
                    ]
                ],
                [
                    "type": "text",
                    "text": "\(previous)\nIs there a new question on this screen?"
                ]
            ]
        ]
    }

    private func send(_ body: [String: Any], beta: String?) async throws -> Data {
        let key = KandyKaneConfig.anthropicAPIKey
        guard !key.isEmpty else { throw ClaudeError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let beta {
            request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.decodingFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw ClaudeError.badResponse(http.statusCode, apiError)
        }
        return data
    }

    // The structured JSON the model returned, or nil if it declined.
    private func parseJSON(_ data: Data) throws -> [String: Any]? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else {
            throw ClaudeError.decodingFailed
        }

        if root["stop_reason"] as? String == "refusal" {
            return nil
        }

        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard
            let inner = text.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: inner) as? [String: Any]
        else {
            throw ClaudeError.decodingFailed
        }
        return parsed
    }
}
