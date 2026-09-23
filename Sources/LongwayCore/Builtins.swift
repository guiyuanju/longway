/// One operand of a built-in form: the type it must have, and the phrase that
/// completes "<form> …" when it does not, e.g. "length expects a list".
struct BuiltinOperand {
    let type: ValueType
    let expectation: String

    init(_ type: ValueType, _ expectation: String) {
        self.type = type
        self.expectation = expectation
    }

    /// An operand whose type is whatever the caller passes - a list element, or
    /// a value stored in a dictionary.
    static let unconstrained = BuiltinOperand(.any, "")
}

enum BuiltinOperands {
    /// A fixed operand list, checked position by position.
    case fixed([BuiltinOperand])
    /// `minimum` or more operands that all take the same type.
    case variadic(minimum: Int, BuiltinOperand)
    /// Alternating keys and values: an even count, with the key type checked
    /// and the value left to whatever reads it back out.
    case alternating(key: BuiltinOperand)
}

/// A built-in value form's type signature. `result` is `.any` when the form's
/// result is unconstrained, so that whatever consumes it decides its type.
struct Builtin {
    let operands: BuiltinOperands
    let result: ValueType

    static func fixed(_ operands: BuiltinOperand..., result: ValueType) -> Builtin {
        Builtin(operands: .fixed(operands), result: result)
    }

    static func variadic(
        _ minimum: Int,
        _ type: ValueType,
        _ expectation: String,
        result: ValueType
    ) -> Builtin {
        Builtin(
            operands: .variadic(minimum: minimum, BuiltinOperand(type, expectation)),
            result: result
        )
    }
}

/// The single declaration of every built-in value form's arity and types.
/// Inference checks every call against this table, so no other pass restates
/// what a form accepts, and `builtinFormNames` is derived from it rather than
/// listed again by hand. Statement-only forms
/// (`notification`, `open-url`, `wait`) produce no value and so are not here;
/// neither are the forms whose type rule is not a signature (`define`, `let`,
/// `let*`, `if`, and `show-result`, which passes its operand's type through).
let builtins: [String: Builtin] = {
    let number = BuiltinOperand(.number, "expects number operands")
    let boolean = BuiltinOperand(.boolean, "expects boolean operands")
    let text = BuiltinOperand(.text, "expects text")
    let list = BuiltinOperand(.list, "expects a list")
    let dictionary = BuiltinOperand(.dictionary, "expects a dictionary")
    let key = BuiltinOperand(.text, "expects a text key")

    var table: [String: Builtin] = [
        "not": .fixed(boolean, result: .boolean),

        "list": Builtin(operands: .variadic(minimum: 0, .unconstrained), result: .list),
        "length": .fixed(list, result: .number),
        "empty?": .fixed(list, result: .boolean),
        "first": .fixed(list, result: .any),
        "last": .fixed(list, result: .any),
        "list-ref": .fixed(list, BuiltinOperand(.number, "expects a number index"), result: .any),

        "dict": Builtin(operands: .alternating(key: key), result: .dictionary),
        "dict-ref": .fixed(dictionary, key, result: .any),
        "dict-set": .fixed(dictionary, key, .unconstrained, result: .dictionary),
        "dict-keys": .fixed(dictionary, result: .list),
        "dict-values": .fixed(dictionary, result: .list),

        "string-append": .variadic(0, .text, "expects text operands", result: .text),
        "number->text": .fixed(BuiltinOperand(.number, "expects a number"), result: .text),
        "split-lines": .fixed(text, result: .list),
        "split-whitespace": .fixed(text, result: .list),
        "split-text": .fixed(
            BuiltinOperand(.text, "expects text operands"),
            BuiltinOperand(.text, "expects text operands"),
            result: .list
        ),

        "choose-from-list": .fixed(list, BuiltinOperand(.text, "expects a text prompt"), result: .any),
        "ask-text": .fixed(text, result: .text),
        "ask-number": .fixed(text, result: .number),
        "format-current-date": .fixed(text, result: .text)
    ]
    for (operation, _) in mathOperations {
        table[operation] = .variadic(2, .number, number.expectation, result: .number)
    }
    for (operation, _) in comparisonConditionCodes {
        table[operation] = .variadic(2, .number, number.expectation, result: .boolean)
    }
    for operation in ["and", "or"] {
        table[operation] = .variadic(2, .boolean, boolean.expectation, result: .boolean)
    }
    return table
}()

/// Source forms that run a Shortcuts action for its effect and produce no value.
let builtinStatementForms: Set<String> = ["notification", "open-url", "wait"]

/// Every name a program may not reuse for one of its own functions.
let builtinFormNames: Set<String> = Set(builtins.keys)
    .union(builtinStatementForms)
    .union(["define", "let", "let*", "if", "show-result"])

/// Longway's arithmetic operators and the symbol each one uses in a Shortcuts
/// Math action.
let mathOperations: [String: String] = ["+": "+", "-": "-", "*": "×", "/": "÷"]

/// The `WFCondition` code for Shortcuts' `is` test, which serves both numeric
/// equality and the `#t` comparison every Boolean condition lowers to.
let equalityConditionCode = 4

/// Longway's comparisons and the `WFCondition` code each one lowers to.
let comparisonConditionCodes: [String: Int] = [
    "<": 0, "<=": 1, ">": 2, ">=": 3, "=": equalityConditionCode
]

func argumentCountMessage(_ form: String, expected: Int, actual: Int) -> String {
    "\(form) expects \(expected) \(expected == 1 ? "argument" : "arguments"), got \(actual)"
}

func requireArgumentCount(
    _ count: Int,
    action form: String,
    arguments: [Expression],
    at location: SourceLocation
) throws {
    guard arguments.count == count else {
        throw LongwayError(
            argumentCountMessage(form, expected: count, actual: arguments.count),
            at: location
        )
    }
}

extension BuiltinOperands {
    /// Checks a call's operand count and answers the per-operand type rules to
    /// apply to it, so inference never restates a form's arity.
    func check(
        _ form: String,
        operands: [Expression],
        at location: SourceLocation
    ) throws -> [BuiltinOperand] {
        switch self {
        case let .fixed(expected):
            try requireArgumentCount(expected.count, action: form, arguments: operands, at: location)
            return expected
        case let .variadic(minimum, operand):
            guard operands.count >= minimum else {
                throw LongwayError(
                    "\(form) expects at least \(minimum) \(minimum == 1 ? "argument" : "arguments"), got \(operands.count)",
                    at: location
                )
            }
            return Array(repeating: operand, count: operands.count)
        case let .alternating(key):
            guard operands.count.isMultiple(of: 2) else {
                throw LongwayError(
                    "\(form) expects alternating keys and values, got \(operands.count) forms",
                    at: location
                )
            }
            return (0..<operands.count).map { $0.isMultiple(of: 2) ? key : .unconstrained }
        }
    }
}
