import Foundation

/// Turns a `CompiledValue.Value` into a referenceable action output, or into the
/// raw plist shape a particular consumer (dictionary item, output parameter,
/// math operand, ...) expects. `materialize*` always emits an action so the
/// result is UUID-referenceable; `emit*` additionally forces a specific runtime
/// type so Shortcuts imports a typed conditional/output correctly.
extension FunctionCompiler {
    func materialize(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalString(text):
            return emitText(ShortcutPlist.textTokenString(text), type: .text, into: &actions)

        case .literalNumber:
            return materializeNumber(value, into: &actions)

        case .literalBoolean:
            return materializeBoolean(value, into: &actions)

        case let .output(output):
            return output
        }
    }

    func materializeBoolean(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalBoolean(boolean):
            return emitText(ShortcutPlist.textTokenString(boolean ? "#t" : "#f"), type: .boolean, into: &actions)
        case let .output(output):
            precondition(typesAreCompatible(output.type, .boolean))
            if output.isRuntimeTyped {
                return ActionOutputReference(type: .boolean, name: output.name, uuid: output.uuid)
            }
            return emitText(
                ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid),
                type: .boolean,
                into: &actions
            )
        case .literalString, .literalNumber:
            preconditionFailure("non-boolean value cannot be materialized as a boolean")
        }
    }

    func emitValue(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalString(text):
            return emitText(ShortcutPlist.textTokenString(text), type: .text, into: &actions)
        case .literalNumber:
            return emitNumber(value, into: &actions)
        case .literalBoolean:
            return emitBoolean(value, into: &actions)
        case let .output(output):
            switch output.type {
            case .text:
                return emitText(
                    ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid),
                    type: .text,
                    into: &actions
                )
            case .number:
                return emitNumber(value, into: &actions)
            case .boolean:
                return emitBoolean(value, into: &actions)
            case .any:
                return emitGeneric(output, into: &actions)
            }
        }
    }

    func emitBoolean(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalBoolean(boolean):
            return emitText(ShortcutPlist.textTokenString(boolean ? "#t" : "#f"), type: .boolean, into: &actions)
        case let .output(output):
            precondition(typesAreCompatible(output.type, .boolean))
            return emitText(
                ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid),
                type: .boolean,
                into: &actions
            )
        case .literalString, .literalNumber:
            preconditionFailure("non-boolean value cannot be emitted as a boolean")
        }
    }

    func emitGeneric(
        _ output: ActionOutputReference,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        let uuid = UUID().uuidString
        let name = "Value"
        actions.append(ShortcutPlist.action("is.workflow.actions.getvariable", parameters: [
            "CustomOutputName": name,
            "WFVariable": ShortcutPlist.actionOutputAttachment(name: output.name, uuid: output.uuid)
        ], uuid: uuid))
        return ActionOutputReference(type: .any, name: name, uuid: uuid)
    }

    func emitText(
        _ text: [String: Any],
        type: ValueType,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.gettext", parameters: [
            "WFTextActionText": text
        ], uuid: uuid))
        return ActionOutputReference(type: type, name: "Text", uuid: uuid)
    }

    func emitNumber(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.number", parameters: [
            "WFNumberActionNumber": numberParameter(value)
        ], uuid: uuid))
        return ActionOutputReference(type: .number, name: "Number", uuid: uuid)
    }

    func materializeNumber(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case .literalNumber:
            return emitNumber(value, into: &actions)

        case let .output(output):
            precondition(typesAreCompatible(output.type, .number))
            if output.isRuntimeTyped {
                return ActionOutputReference(type: .number, name: output.name, uuid: output.uuid)
            }
            return emitNumber(value, into: &actions)

        case .literalString, .literalBoolean:
            preconditionFailure("non-number value cannot be materialized as a number")
        }
    }

    func numberParameter(_ value: CompiledValue.Value) -> Any {
        switch value {
        case let .literalNumber(number):
            return number
        case let .output(output):
            return ShortcutPlist.actionOutputAttachment(name: output.name, uuid: output.uuid)
        case .literalString, .literalBoolean:
            preconditionFailure("non-number value cannot be used as a number parameter")
        }
    }

    func outputParameter(
        _ value: CompiledValue.Value,
        actions: inout [[String: Any]]
    ) -> [String: Any] {
        switch value {
        case let .literalString(string):
            return ShortcutPlist.textTokenString(string)
        case let .literalBoolean(boolean):
            return ShortcutPlist.textTokenString(boolean ? "#t" : "#f")
        case .literalNumber:
            let output = emitNumber(value, into: &actions)
            return ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        case let .output(output):
            return ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        }
    }

    func dictionaryItem(
        key: String,
        value: CompiledValue.Value,
        expectedType: ValueType
    ) -> [String: Any] {
        let valueType = expectedType == .any ? value.type : expectedType
        let itemType = valueType == .number ? 3 : 0
        let dictionaryValue: [String: Any]
        switch value {
        case let .literalString(string):
            dictionaryValue = ShortcutPlist.textTokenString(string)
        case let .literalNumber(number):
            dictionaryValue = ShortcutPlist.textTokenString(ShortcutPlist.formatNumber(number))
        case let .literalBoolean(boolean):
            dictionaryValue = ShortcutPlist.textTokenString(boolean ? "#t" : "#f")
        case let .output(output):
            dictionaryValue = ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        }
        return [
            "WFItemType": itemType,
            "WFKey": ShortcutPlist.textTokenString(key),
            "WFValue": dictionaryValue
        ]
    }
}
