import Foundation

struct ClaudeResponse {
    let hasQuestion: Bool
    let question: String
    let answer: String

    static let none = ClaudeResponse(hasQuestion: false, question: "", answer: "")
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

    Your answer is read aloud by a speech synthesizer, so write it the way \
    you'd say it: plain sentences, no symbols, lists, or formatting. Say math \
    in words, for example "x squared plus three x".

    - For math problems, walk through the steps briefly, then give the final \
    answer. Keep it under about 120 words.
    - For multiple choice, say the correct option's letter and its text.
    - Otherwise, answer directly in a sentence or two.

    Set hasQuestion to false and leave question and answer empty when:
    - there's no question on screen,
    - the screen shows this app itself (a black screen titled KandyKane with \
    a preview and a list of past answers), or
    - it's the same question as the previous one you were told about.

    In question, restate the question in a few words.
    """

    private let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "hasQuestion": ["type": "boolean"],
            "question": ["type": "string"],
            "answer": ["type": "string"]
        ],
        "required": ["hasQuestion", "question", "answer"],
        "additionalProperties": false
    ]

    func analyze(frame jpegData: Data, previousQuestion: String) async throws -> ClaudeResponse {
        let key = KandyKaneConfig.anthropicAPIKey
        guard !key.isEmpty else { throw ClaudeError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 90

        let previous = previousQuestion.isEmpty
            ? "No question has been answered yet."
            : "The previous question was: \(previousQuestion)"

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
            "messages": [[
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
            ]]
        ]

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

        return try parse(data)
    }

    private func parse(_ data: Data) throws -> ClaudeResponse {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else {
            throw ClaudeError.decodingFailed
        }

        // A declined screenshot is treated like one without a question.
        if root["stop_reason"] as? String == "refusal" {
            return .none
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

        return ClaudeResponse(
            hasQuestion: parsed["hasQuestion"] as? Bool ?? false,
            question: parsed["question"] as? String ?? "",
            answer: parsed["answer"] as? String ?? ""
        )
    }
}
