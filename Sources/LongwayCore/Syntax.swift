import Foundation

public struct SourceLocation: Equatable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct LongwayError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public let location: SourceLocation

    public init(_ message: String, at location: SourceLocation) {
        self.message = message
        self.location = location
    }

    public var description: String {
        "\(location.line):\(location.column): error: \(message)"
    }
}

struct Expression: Equatable {
    let value: Value
    let location: SourceLocation

    indirect enum Value: Equatable {
        case list([Expression])
        case symbol(String)
        case string(String)
        case number(Double)
        case boolean(Bool)
    }
}

extension Expression {
    var symbol: String? {
        guard case let .symbol(value) = self.value else { return nil }
        return value
    }
}

/// A validated `let` / `let*` form. Inference and codegen both walk one, so the
/// shape is checked here once rather than in each pass.
struct LetForm {
    let name: String
    let isSequential: Bool
    let bindings: [(name: String, value: Expression)]
    let body: [Expression]

    init(_ parts: [Expression], at location: SourceLocation) throws {
        name = parts.first?.symbol == "let*" ? "let*" : "let"
        isSequential = name == "let*"

        guard parts.count >= 3 else {
            throw LongwayError("\(name) expects bindings and at least one body form", at: location)
        }
        guard case let .list(pairs) = parts[1].value else {
            throw LongwayError("\(name) bindings must be a list", at: parts[1].location)
        }

        var bindings: [(name: String, value: Expression)] = []
        var names = Set<String>()
        for pair in pairs {
            guard case let .list(parts) = pair.value, parts.count == 2 else {
                throw LongwayError("\(name) binding must contain a name and value", at: pair.location)
            }
            guard case let .symbol(bindingName) = parts[0].value else {
                throw LongwayError("\(name) binding name must be a symbol", at: parts[0].location)
            }
            // `let*` bindings are sequential, so a later one may deliberately
            // shadow an earlier name.
            if !isSequential, !names.insert(bindingName).inserted {
                throw LongwayError("duplicate let binding '\(bindingName)'", at: parts[0].location)
            }
            bindings.append((bindingName, parts[1]))
        }
        self.bindings = bindings
        self.body = Array(parts.dropFirst(2))
    }
}
