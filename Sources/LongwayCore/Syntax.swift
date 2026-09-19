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
