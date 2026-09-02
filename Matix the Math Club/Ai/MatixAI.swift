import Foundation

enum MatixAISource: String {
    case googleSearch = "Google Search"
    case duckDuckGo = "DuckDuckGo"
    case offlineCalculator = "Offline Calculator"
    case offlineLesson = "Offline Lesson Generator"
    case unavailable = "Unavailable"
}

struct MatixAIResponse {
    let source: MatixAISource
    let title: String
    let text: String
    let url: URL?
}

enum MatixAIError: Error {
    case invalidQuestion
    case invalidMathExpression
    case divideByZero
}

final class MatixAI {
    private let session: URLSession
    private let googleAPIKey: String?
    private let googleSearchEngineID: String?

    init(
        session: URLSession = .shared,
        googleAPIKey: String? = ProcessInfo.processInfo.environment["GOOGLE_SEARCH_API_KEY"],
        googleSearchEngineID: String? = ProcessInfo.processInfo.environment["GOOGLE_SEARCH_ENGINE_ID"]
    ) {
        self.session = session
        self.googleAPIKey = googleAPIKey
        self.googleSearchEngineID = googleSearchEngineID
    }

    func answer(_ question: String) async -> MatixAIResponse {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return MatixAIResponse(source: .unavailable, title: "Missing Question", text: "Please ask a question first.", url: nil)
        }

        if let expression = Self.extractMathExpression(from: query) {
            do {
                let value = try Self.evaluateMathExpression(expression)
                return MatixAIResponse(
                    source: .offlineCalculator,
                    title: "Math Result",
                    text: "\(expression) = \(Self.formatNumber(value))",
                    url: nil
                )
            } catch {
                return MatixAIResponse(
                    source: .offlineCalculator,
                    title: "Math Error",
                    text: "I couldn't evaluate that expression. Use numbers, parentheses, and + - * / ^.",
                    url: nil
                )
            }
        }

        if let topic = Self.extractLessonTopic(from: query) {
            let lesson = Self.generateLesson(for: topic, level: Self.detectLessonLevel(from: query))
            return MatixAIResponse(source: .offlineLesson, title: "Lesson: \(topic)", text: lesson, url: nil)
        }

        do {
            if let google = try await googleSearch(query: query) {
                return google
            }
        } catch {
            // Fall through to DuckDuckGo if Google Search fails.
        }

        do {
            if let duck = try await duckDuckGoSearch(query: query) {
                return duck
            }
        } catch {
            // Fall through to offline guidance if DuckDuckGo also fails.
        }

        return MatixAIResponse(
            source: .unavailable,
            title: "No Live Result",
            text: "I couldn't find a live web result. You can ask for a math expression or say \"lesson on <topic>\" to use offline mode.",
            url: nil
        )
    }
}

private extension MatixAI {
    struct GoogleSearchPayload: Decodable {
        struct Item: Decodable {
            let title: String?
            let snippet: String?
            let link: String?
        }

        let items: [Item]?
    }

    struct DuckDuckGoPayload: Decodable {
        struct Topic: Decodable {
            let text: String?
            let topics: [Topic]?

            enum CodingKeys: String, CodingKey {
                case text = "Text"
                case topics = "Topics"
            }
        }

        let heading: String?
        let abstractText: String?
        let abstractSource: String?
        let abstractURL: String?
        let answer: String?
        let relatedTopics: [Topic]?

        enum CodingKeys: String, CodingKey {
            case heading = "Heading"
            case abstractText = "AbstractText"
            case abstractSource = "AbstractSource"
            case abstractURL = "AbstractURL"
            case answer = "Answer"
            case relatedTopics = "RelatedTopics"
        }
    }

    func googleSearch(query: String) async throws -> MatixAIResponse? {
        guard let apiKey = googleAPIKey, !apiKey.isEmpty,
              let engineID = googleSearchEngineID, !engineID.isEmpty else {
            return nil
        }

        var components = URLComponents(string: "https://www.googleapis.com/customsearch/v1")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: engineID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: "1")
        ]
        guard let url = components?.url else { throw MatixAIError.invalidQuestion }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        let payload = try JSONDecoder().decode(GoogleSearchPayload.self, from: data)
        guard let item = payload.items?.first,
              let snippet = item.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
              !snippet.isEmpty else {
            return nil
        }

        return MatixAIResponse(
            source: .googleSearch,
            title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? query,
            text: snippet,
            url: item.link.flatMap(URL.init(string:))
        )
    }

    func duckDuckGoSearch(query: String) async throws -> MatixAIResponse? {
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "t", value: "matix")
        ]
        guard let url = components?.url else { throw MatixAIError.invalidQuestion }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        let payload = try JSONDecoder().decode(DuckDuckGoPayload.self, from: data)
        let direct = payload.abstractText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? payload.answer?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let related = direct ?? Self.firstRelatedTopic(from: payload.relatedTopics)
        guard let text = related, !text.isEmpty else { return nil }

        let title = payload.heading?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? query

        return MatixAIResponse(
            source: .duckDuckGo,
            title: title,
            text: text,
            url: payload.abstractURL.flatMap(URL.init(string:))
        )
    }

    static func firstRelatedTopic(from topics: [DuckDuckGoPayload.Topic]?) -> String? {
        guard let topics else { return nil }
        for topic in topics {
            if let text = topic.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if let nested = firstRelatedTopic(from: topic.topics) {
                return nested
            }
        }
        return nil
    }

    static func extractMathExpression(from query: String) -> String? {
        let lowered = query.lowercased()
        let strippedPrefixes = ["calculate", "what is", "solve", "evaluate"].reduce(query) { text, prefix in
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.lowercased().hasPrefix(prefix + " ") {
                return String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return normalized
        }

        let candidate = strippedPrefixes.trimmingCharacters(in: CharacterSet(charactersIn: " ?!."))
        guard candidate.range(of: #"^[0-9\.\+\-\*\/\^\(\)\s]+$"#, options: .regularExpression) != nil else {
            if lowered.range(of: #"[0-9].*[\+\-\*\/\^].*[0-9]"#, options: .regularExpression) == nil {
                return nil
            }
            return nil
        }
        return candidate
    }

    static func detectLessonLevel(from query: String) -> String {
        let lowered = query.lowercased()
        if lowered.contains("advanced") { return "advanced" }
        if lowered.contains("intermediate") { return "intermediate" }
        return "beginner"
    }

    static func extractLessonTopic(from query: String) -> String? {
        let lowered = query.lowercased()
        let markers = ["lesson on ", "teach me ", "explain "]
        for marker in markers {
            if let range = lowered.range(of: marker) {
                let topic = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !topic.isEmpty { return topic }
            }
        }
        return nil
    }

    static func generateLesson(for topic: String, level: String) -> String {
        let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let difficulty = level.capitalized
        let hook: String
        let workedExample: String
        let practice: String

        if cleanTopic.lowercased().contains("fraction") {
            hook = "A fraction shows equal parts of a whole. The denominator tells total parts, and the numerator tells chosen parts."
            workedExample = "Example: 3/4 + 1/8 = 6/8 + 1/8 = 7/8."
            practice = "Try: 5/6 - 1/3"
        } else if cleanTopic.lowercased().contains("algebra") || cleanTopic.lowercased().contains("equation") {
            hook = "Algebra is balancing both sides of an equation by doing the same move to each side."
            workedExample = "Example: 2x + 3 = 11 -> 2x = 8 -> x = 4."
            practice = "Try: 3x - 5 = 16"
        } else if cleanTopic.lowercased().contains("geometry") {
            hook = "Geometry studies shape, size, and space using definitions, formulas, and visual reasoning."
            workedExample = "Example: Area of a rectangle with width 5 and height 9 is 5 * 9 = 45."
            practice = "Try: Perimeter of a rectangle with width 7 and height 4"
        } else {
            hook = "\(cleanTopic) becomes easier when we split it into clear rules, a worked example, and short practice."
            workedExample = "Example pattern: identify the rule, apply it step by step, and check the final result."
            practice = "Try: write one problem about \(cleanTopic) and solve it in 3 steps."
        }

        return """
        Level: \(difficulty)

        1) Big idea
        \(hook)

        2) Worked example
        \(workedExample)

        3) Practice
        \(practice)
        """
    }

    enum MathToken: Equatable {
        case number(Double)
        case op(Character)
        case leftParen
        case rightParen
    }

    static func evaluateMathExpression(_ expression: String) throws -> Double {
        let tokens = try tokenize(expression)
        let rpn = try toRPN(tokens)
        return try evalRPN(rpn)
    }

    static func tokenize(_ expression: String) throws -> [MathToken] {
        let chars = Array(expression.replacingOccurrences(of: " ", with: ""))
        if chars.isEmpty { throw MatixAIError.invalidMathExpression }
        var tokens: [MathToken] = []
        var index = 0

        func previousAllowsUnaryMinus() -> Bool {
            guard let prev = tokens.last else { return true }
            switch prev {
            case .op, .leftParen: return true
            case .number, .rightParen: return false
            }
        }

        while index < chars.count {
            let ch = chars[index]
            if ch.isNumber || ch == "." {
                var number = String(ch)
                index += 1
                while index < chars.count, chars[index].isNumber || chars[index] == "." {
                    number.append(chars[index])
                    index += 1
                }
                guard let value = Double(number) else { throw MatixAIError.invalidMathExpression }
                tokens.append(.number(value))
                continue
            }

            if "+-*/^".contains(ch) {
                if ch == "-", previousAllowsUnaryMinus() {
                    tokens.append(.number(0))
                }
                tokens.append(.op(ch))
                index += 1
                continue
            }

            if ch == "(" {
                tokens.append(.leftParen)
                index += 1
                continue
            }

            if ch == ")" {
                tokens.append(.rightParen)
                index += 1
                continue
            }

            throw MatixAIError.invalidMathExpression
        }

        return tokens
    }

    static func toRPN(_ tokens: [MathToken]) throws -> [MathToken] {
        var output: [MathToken] = []
        var stack: [MathToken] = []

        func precedence(of op: Character) -> Int {
            switch op {
            case "+", "-": return 1
            case "*", "/": return 2
            case "^": return 3
            default: return -1
            }
        }

        func isRightAssociative(_ op: Character) -> Bool { op == "^" }

        for token in tokens {
            switch token {
            case .number:
                output.append(token)
            case .op(let current):
                while let top = stack.last {
                    guard case .op(let previous) = top else { break }
                    let currentPrec = precedence(of: current)
                    let previousPrec = precedence(of: previous)
                    let shouldPop = isRightAssociative(current) ? (currentPrec < previousPrec) : (currentPrec <= previousPrec)
                    if shouldPop {
                        output.append(stack.removeLast())
                    } else {
                        break
                    }
                }
                stack.append(token)
            case .leftParen:
                stack.append(token)
            case .rightParen:
                var foundLeft = false
                while let top = stack.last {
                    stack.removeLast()
                    if case .leftParen = top {
                        foundLeft = true
                        break
                    }
                    output.append(top)
                }
                if !foundLeft { throw MatixAIError.invalidMathExpression }
            }
        }

        while let top = stack.popLast() {
            if case .leftParen = top { throw MatixAIError.invalidMathExpression }
            output.append(top)
        }

        return output
    }

    static func evalRPN(_ tokens: [MathToken]) throws -> Double {
        var stack: [Double] = []

        for token in tokens {
            switch token {
            case .number(let value):
                stack.append(value)
            case .op(let op):
                guard stack.count >= 2 else { throw MatixAIError.invalidMathExpression }
                let rhs = stack.removeLast()
                let lhs = stack.removeLast()
                let result: Double
                switch op {
                case "+":
                    result = lhs + rhs
                case "-":
                    result = lhs - rhs
                case "*":
                    result = lhs * rhs
                case "/":
                    if rhs == 0 { throw MatixAIError.divideByZero }
                    result = lhs / rhs
                case "^":
                    result = pow(lhs, rhs)
                default:
                    throw MatixAIError.invalidMathExpression
                }
                stack.append(result)
            case .leftParen, .rightParen:
                throw MatixAIError.invalidMathExpression
            }
        }

        guard stack.count == 1, let value = stack.first else {
            throw MatixAIError.invalidMathExpression
        }
        return value
    }

    static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.8g", value)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
