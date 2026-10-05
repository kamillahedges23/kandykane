import Foundation

struct ClaudeResponse {
    let hasQuestion: Bool
    let question: String
    let answer: String
}

enum ClaudeError: LocalizedError {
    case missingKey
    case badResponse(Int, String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No API key set. Add it on the main screen."
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
    You look at a screenshot and decide whether a question, problem, or \
    exercise is visible. Reply with JSON only, no markdown fences, in this \
    exact shape:

    {"hasQuestion": true/false, "question": "...", "answer": "..."}

    If no question is visible, set hasQuestion to false and leave the other \
    fields empty. If a question is visible, restate it briefly in "question" \
    and give a clear spoken-style answer in "answer". Keep the answer under \
    60 words and write it to be read aloud, so avoid symbols, bullet points, \
    and formatting.
    """

    func analyze(frame jpegData: Data) async throws -> ClaudeResponse {
        guard let key = KandyKaneConfig.sharedDefaults?
            .string(forKey: KandyKaneConfig.apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw ClaudeError.missingKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            // Thinking is always on for this model and counts toward
            // max_tokens, so leave headroom and keep effort low.
            "max_tokens": 2048,
            "output_config": ["effort": "low"],
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
                        "text": "Is there a question on this screen?"
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

        let text = content
            .compactMap { $0["text"] as? String }
            .joined()
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
