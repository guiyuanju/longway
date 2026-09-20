import Foundation

/// Dictionaries. A Longway dictionary is a Shortcuts dictionary: text keys over
/// untyped values, built by `is.workflow.actions.dictionary` and read by Get
/// Dictionary Value. Values carry no static type, so a read produces a generic
/// value that its consumer re-types, exactly like a list element.
/// Shortcuts reads a `.` in a key as a key path into nested content, so a key
/// containing one does not address a literal key of that name.
extension FunctionCompiler {
    func compileDictionaryOperation(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        switch operation {
        case "dict":
            return try compileDictionaryLiteral(operands, at: location, environment: environment)
        case "dict-ref":
            return try compileDictionaryRef(operands, at: location, environment: environment)
        case "dict-set":
            return try compileDictionarySet(operands, at: location, environment: environment)
        case "dict-keys":
            return try compileDictionaryContents(
                operation,
                valueType: "All Keys",
                name: "Dictionary Keys",
                operands: operands,
                at: location,
                environment: environment
            )
        case "dict-values":
            return try compileDictionaryContents(
                operation,
                valueType: "All Values",
                name: "Dictionary Values",
                operands: operands,
                at: location,
                environment: environment
            )
        default:
            preconditionFailure("unknown dictionary operation")
        }
    }

    private func compileDictionaryLiteral(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        guard operands.count.isMultiple(of: 2) else {
            throw LongwayError(
                "dict expects alternating keys and values, got \(operands.count) forms",
                at: location
            )
        }

        var actions: [[String: Any]] = []
        var items: [[String: Any]] = []
        var literalKeys = Set<String>()
        for pair in stride(from: 0, to: operands.count, by: 2) {
            let keyExpression = operands[pair]
            let key = try compileDictionaryKey("dict", keyExpression, environment: environment)
            if case let .literalString(literal) = key.value, !literalKeys.insert(literal).inserted {
                throw LongwayError("duplicate dict key '\(literal)'", at: keyExpression.location)
            }
            actions.append(contentsOf: key.actions)

            let value = try compileValue(operands[pair + 1], environment: environment)
            actions.append(contentsOf: value.actions)
            items.append(dictionaryItem(
                keyToken: dictionaryKeyToken(key.value),
                value: value.value,
                expectedType: value.value.type
            ))
        }

        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.dictionary", parameters: [
            "CustomOutputName": "Dictionary",
            "WFItems": ShortcutPlist.dictionaryFieldValue(items: items)
        ], uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(type: .dictionary, name: "Dictionary", uuid: uuid))
        )
    }

    private func compileDictionaryRef(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(2, action: "dict-ref", arguments: operands, at: location)
        let dictionary = try compileDictionaryOperand("dict-ref", operands[0], environment: environment)
        var actions = dictionary.actions
        let key = try compileDictionaryKey("dict-ref", operands[1], environment: environment)
        actions.append(contentsOf: key.actions)

        let name = "Dictionary Value"
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.getvalueforkey", parameters: [
            "CustomOutputName": name,
            "WFDictionaryKey": dictionaryKeyParameter(key.value),
            "WFGetDictionaryValueType": "Value",
            "WFInput": ShortcutPlist.actionOutputAttachment(
                name: dictionary.reference.name,
                uuid: dictionary.reference.uuid
            )
        ], uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(
                type: .any,
                name: name,
                uuid: uuid,
                isRuntimeTyped: false
            ))
        )
    }

    /// `dict-keys` and `dict-values` are the same action as `dict-ref` under a
    /// different `WFGetDictionaryValueType`, and both answer with a list.
    private func compileDictionaryContents(
        _ operation: String,
        valueType: String,
        name: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: operation, arguments: operands, at: location)
        let dictionary = try compileDictionaryOperand(operation, operands[0], environment: environment)

        var actions = dictionary.actions
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.getvalueforkey", parameters: [
            "CustomOutputName": name,
            "WFGetDictionaryValueType": valueType,
            "WFInput": ShortcutPlist.actionOutputAttachment(
                name: dictionary.reference.name,
                uuid: dictionary.reference.uuid
            )
        ], uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(
                type: .list,
                name: name,
                uuid: uuid,
                isRuntimeTyped: false
            ))
        )
    }

    /// `(dict-set d k v)` answers a new dictionary rather than mutating `d`.
    /// The value rides in a text-shaped field, which would flatten a list or a
    /// nested dictionary, so those have to be built with `dict` instead.
    private func compileDictionarySet(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(3, action: "dict-set", arguments: operands, at: location)
        let dictionary = try compileDictionaryOperand("dict-set", operands[0], environment: environment)
        var actions = dictionary.actions
        let key = try compileDictionaryKey("dict-set", operands[1], environment: environment)
        actions.append(contentsOf: key.actions)

        let value = try compileValue(operands[2], environment: environment)
        try requireStorableInDictionaryField(value.value.type, at: operands[2].location)
        actions.append(contentsOf: value.actions)

        let name = "Dictionary"
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.setvalueforkey", parameters: [
            "CustomOutputName": name,
            // Set Dictionary Value names its dictionary input `WFDictionary`,
            // not the `WFInput` its Get counterpart uses.
            "WFDictionary": ShortcutPlist.actionOutputAttachment(
                name: dictionary.reference.name,
                uuid: dictionary.reference.uuid
            ),
            "WFDictionaryKey": dictionaryKeyParameter(key.value),
            "WFDictionaryValue": dictionaryValue(value.value)
        ], uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(
                type: .dictionary,
                name: name,
                uuid: uuid,
                isRuntimeTyped: false
            ))
        )
    }

    /// Like a list, a dictionary always comes from an action output - there is
    /// no literal dictionary value - so an operand that did not compile to one
    /// cannot be read from.
    private func compileDictionaryOperand(
        _ operation: String,
        _ expression: Expression,
        environment: CompileEnvironment
    ) throws -> (actions: [[String: Any]], reference: ActionOutputReference) {
        let compiled = try compileValue(expression, environment: environment)
        guard typesAreCompatible(compiled.value.type, .dictionary),
              case let .output(output) = compiled.value
        else {
            throw LongwayError("\(operation) expects a dictionary", at: expression.location)
        }
        return (compiled.actions, output)
    }

    private func compileDictionaryKey(
        _ operation: String,
        _ expression: Expression,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        let compiled = try compileValue(expression, environment: environment)
        guard typesAreCompatible(compiled.value.type, .text) else {
            throw LongwayError("\(operation) expects a text key", at: expression.location)
        }
        return compiled
    }

    /// `WFDictionaryKey` is an ordinary text field: Apple's own shortcuts write
    /// a bare string for a literal key, and a computed one needs the token
    /// string every other text reference here uses.
    private func dictionaryKeyParameter(_ value: CompiledValue.Value) -> Any {
        switch value {
        case let .literalString(string):
            return string
        case let .output(output):
            return ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        case .literalNumber, .literalBoolean:
            preconditionFailure("a dictionary key is always text")
        }
    }

    private func dictionaryKeyToken(_ value: CompiledValue.Value) -> [String: Any] {
        switch value {
        case let .literalString(string):
            return ShortcutPlist.textTokenString(string)
        case let .output(output):
            return ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        case .literalNumber, .literalBoolean:
            preconditionFailure("a dictionary key is always text")
        }
    }
}

func requireStorableInDictionaryField(
    _ type: ValueType,
    at location: SourceLocation
) throws {
    guard type == .list || type == .dictionary else { return }
    throw LongwayError(
        "dict-set cannot store \(type.pluralName); build the dictionary with dict instead",
        at: location
    )
}
