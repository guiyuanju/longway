struct Parser {
    private let tokens: [Token]
    private var index = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    mutating func parseProgram() throws -> [Expression] {
        guard current.kind != .eof else {
            throw LongwayError("expected at least one function definition", at: current.location)
        }

        var expressions: [Expression] = []
        while current.kind != .eof {
            expressions.append(try parseExpression())
        }
        return expressions
    }

    private var current: Token {
        tokens[index]
    }

    private mutating func consume() -> Token {
        defer { index += 1 }
        return current
    }

    private mutating func parseExpression() throws -> Expression {
        let token = consume()
        switch token.kind {
        case .leftParen:
            var values: [Expression] = []
            while current.kind != .rightParen {
                if current.kind == .eof {
                    throw LongwayError("expected ')'", at: token.location)
                }
                values.append(try parseExpression())
            }
            _ = consume()
            return Expression(value: .list(values), location: token.location)
        case .rightParen:
            throw LongwayError("unexpected ')'", at: token.location)
        case let .symbol(value):
            return Expression(value: .symbol(value), location: token.location)
        case let .string(value):
            return Expression(value: .string(value), location: token.location)
        case let .number(value):
            return Expression(value: .number(value), location: token.location)
        case let .boolean(value):
            return Expression(value: .boolean(value), location: token.location)
        case .eof:
            throw LongwayError("unexpected end of file", at: token.location)
        }
    }
}
