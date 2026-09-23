enum ValueType: String, Equatable, Sendable {
    case text
    case number
    case boolean
    case list
    case dictionary
    case any

    var name: String {
        switch self {
        case .text: "text"
        case .number: "number"
        case .boolean: "boolean"
        case .list: "list"
        case .dictionary: "dictionary"
        case .any: "value"
        }
    }

    var pluralName: String {
        switch self {
        case .text: "text values"
        case .number: "numbers"
        case .boolean: "booleans"
        case .list: "lists"
        case .dictionary: "dictionaries"
        case .any: "values"
        }
    }
}

func typesAreCompatible(_ left: ValueType, _ right: ValueType) -> Bool {
    left == .any || right == .any || left == right
}

func mergeTypes(_ left: ValueType, _ right: ValueType) -> ValueType? {
    if left == .any { return right }
    if right == .any { return left }
    return left == right ? left : nil
}
