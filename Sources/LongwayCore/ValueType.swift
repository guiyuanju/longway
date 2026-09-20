enum ValueType: Equatable {
    case text
    case number
    case boolean
    case list
    case any

    var name: String {
        switch self {
        case .text: "text"
        case .number: "number"
        case .boolean: "boolean"
        case .list: "list"
        case .any: "value"
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
