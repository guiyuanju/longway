let comparisonOperators: Set<String> = ["=", "<", "<=", ">", ">="]

/// Shortcut condition code for `is`, the equality comparison.
let equalityConditionCode = 4

/// Value forms over Shortcuts lists. `list` builds one; the rest read from one.
let listOperations: Set<String> = ["list", "length", "list-ref", "first", "last", "empty?"]

func mathOperation(_ symbol: String) -> String? {
    switch symbol {
    case "+": "+"
    case "-": "-"
    case "*": "×"
    case "/": "÷"
    default: nil
    }
}

func functionArgumentCountMessage(
    _ function: String,
    expected: Int,
    actual: Int
) -> String {
    let noun = expected == 1 ? "argument" : "arguments"
    return "\(function) expects \(expected) \(noun), got \(actual)"
}

func requireArgumentCount(
    _ count: Int,
    action: String,
    arguments: [Expression],
    at location: SourceLocation
) throws {
    guard arguments.count == count else {
        let noun = count == 1 ? "argument" : "arguments"
        throw LongwayError("\(action) expects \(count) \(noun), got \(arguments.count)", at: location)
    }
}
