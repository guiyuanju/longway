import Foundation

/// Lists. A Longway list is a Shortcuts list: a flat, ordered collection of
/// runtime values, built by `is.workflow.actions.list` and read by the
/// Get Item from List and Count actions. Elements carry no static type, so
/// every read produces a generic value that its consumer re-types.
/// Source indexes are 0-based like Scheme's `list-ref`; Shortcuts indexes from
/// 1, so this file adds the offset (statically for a literal index, with a
/// Math action for a computed one).
extension FunctionCompiler {
    func compileListLiteral(
        _ operands: [Expression],
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        var actions: [[String: Any]] = []
        var items: [Any] = []
        for operand in operands {
            let element = try compileValue(operand, environment: environment)
            // A `WFItems` entry is a plain string or a text token string, which
            // flattens a list to newline-joined text and a dictionary to JSON.
            guard element.value.type != .list, element.value.type != .dictionary else {
                throw LongwayError(
                    "list elements cannot be \(element.value.type.pluralName)",
                    at: operand.location
                )
            }
            actions.append(contentsOf: element.actions)
            items.append(listItem(element.value))
        }

        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.list", parameters: [
            "WFItems": items
        ], uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(type: .list, name: "List", uuid: uuid))
        )
    }

    func compileLength(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: "length", arguments: operands, at: location)
        let list = try compileListOperand("length", operands[0], environment: environment)

        var actions = list.actions
        let uuid = UUID().uuidString
        // The Count action names its input `Input`, not the `WFInput` every
        // other action in this compiler uses.
        actions.append(ShortcutPlist.action("is.workflow.actions.count", parameters: [
            "CustomOutputName": "Count",
            "Input": ShortcutPlist.actionOutputAttachment(name: list.reference.name, uuid: list.reference.uuid),
            "WFCountType": "Items"
        ], uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(type: .number, name: "Count", uuid: uuid))
        )
    }

    /// `(empty? xs)` is `(= (length xs) 0)`: Shortcuts has no emptiness test, and
    /// Count's output is a real number, so the existing equality lowering applies.
    func compileEmpty(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: "empty?", arguments: operands, at: location)
        let count = try compileLength(operands, at: location, environment: environment)
        guard case let .output(countOutput) = count.value else {
            preconditionFailure("length must produce an action output")
        }

        let comparison = lowerComparison(
            "=",
            comparison: NumericComparison(left: countOutput, right: .literalNumber(0)),
            trueBranch: CompiledValue(actions: [], value: .literalBoolean(true)),
            falseBranch: CompiledValue(actions: [], value: .literalBoolean(false))
        )
        return CompiledValue(actions: count.actions + comparison.actions, value: comparison.value)
    }

    func compileItem(
        _ operation: String,
        specifier: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: operation, arguments: operands, at: location)
        let list = try compileListOperand(operation, operands[0], environment: environment)
        var actions = list.actions
        return getItemFromList(list.reference, specifier: specifier, index: nil, into: &actions)
    }

    func compileListRef(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(2, action: "list-ref", arguments: operands, at: location)
        let list = try compileListOperand("list-ref", operands[0], environment: environment)
        var actions = list.actions

        let index = try compileValue(operands[1], environment: environment)
        guard typesAreCompatible(index.value.type, .number) else {
            throw LongwayError("list-ref expects a number index", at: operands[1].location)
        }
        actions.append(contentsOf: index.actions)
        let shortcutIndex = try shortcutIndexParameter(index.value, at: operands[1].location, into: &actions)
        return getItemFromList(list.reference, specifier: "Item At Index", index: shortcutIndex, into: &actions)
    }

    private func getItemFromList(
        _ list: ActionOutputReference,
        specifier: String,
        index: Any?,
        into actions: inout [[String: Any]]
    ) -> CompiledValue {
        let name = "List Item"
        var parameters: [String: Any] = [
            "CustomOutputName": name,
            "WFInput": ShortcutPlist.actionOutputAttachment(name: list.name, uuid: list.uuid),
            "WFItemSpecifier": specifier
        ]
        if let index {
            parameters["WFItemIndex"] = index
        }

        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.getitemfromlist", parameters: parameters, uuid: uuid))
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

    /// Converts a 0-based source index into the 1-based index Shortcuts wants.
    /// A literal index is offset at compile time; a computed one needs a Math
    /// action, because `WFItemIndex` holds a single value, not an expression.
    private func shortcutIndexParameter(
        _ index: CompiledValue.Value,
        at location: SourceLocation,
        into actions: inout [[String: Any]]
    ) throws -> Any {
        if case let .literalNumber(number) = index {
            guard number >= 0, number == number.rounded() else {
                throw LongwayError("list-ref index must be a whole number that is not negative", at: location)
            }
            return number + 1
        }

        let base = materializeNumber(index, into: &actions)
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.math", parameters: [
            "WFInput": ShortcutPlist.actionOutputAttachment(name: base.name, uuid: base.uuid),
            "WFMathOperation": "+",
            "WFMathOperand": 1.0
        ], uuid: uuid))
        return ShortcutPlist.actionOutputAttachment(name: "Calculation Result", uuid: uuid)
    }

    /// A list always comes from an action output - there is no literal list value -
    /// so a list operand that did not compile to one cannot be read from.
    func compileListOperand(
        _ operation: String,
        _ expression: Expression,
        environment: CompileEnvironment
    ) throws -> (actions: [[String: Any]], reference: ActionOutputReference) {
        let compiled = try compileValue(expression, environment: environment)
        guard typesAreCompatible(compiled.value.type, .list),
              case let .output(output) = compiled.value
        else {
            throw LongwayError("\(operation) expects a list", at: expression.location)
        }
        return (compiled.actions, output)
    }
}
