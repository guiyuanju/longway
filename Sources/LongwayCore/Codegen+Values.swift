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
            case .list:
                return emitPassthrough(output, type: .list, name: "List", into: &actions)
            case .dictionary:
                return emitPassthrough(output, type: .dictionary, name: "Dictionary", into: &actions)
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
        emitPassthrough(output, type: .any, name: "Value", into: &actions)
    }

    /// Re-publishes a value under a fresh UUID without coercing it. Values that
    /// have no typed producer action - generic ones, and lists and dictionaries,
    /// which Shortcuts would flatten to newline-joined text and to JSON if
    /// passed through Text or Number - go through Get Variable, which carries
    /// the runtime value across unchanged.
    func emitPassthrough(
        _ output: ActionOutputReference,
        type: ValueType,
        name: String,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.getvariable", parameters: [
            "CustomOutputName": name,
            "WFVariable": ShortcutPlist.actionOutputAttachment(name: output.name, uuid: output.uuid)
        ], uuid: uuid))
        return ActionOutputReference(type: type, name: name, uuid: uuid)
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

    /// Stop and Output carries a list the same way it carries any other value:
    /// one attachment filling the whole token string. The Shortcuts editor
    /// writes exactly this for a List variable, so a list result needs no
    /// special encoding here.
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

    /// One `WFItems` entry of a List action. `WFItems` is a `WFContentArrayParameter`,
    /// not the keyed field list a Dictionary action takes: Apple's own shortcuts
    /// write a plain string per literal item, and an item that references another
    /// action's output carries that reference as a text token string. Wrapping
    /// either one in a `WFItemType`/`WFValue` pair makes Shortcuts read the whole
    /// array as a single item.
    func listItem(_ value: CompiledValue.Value) -> Any {
        switch value {
        case let .literalString(string):
            return string
        case let .literalNumber(number):
            return ShortcutPlist.formatNumber(number)
        case let .literalBoolean(boolean):
            return boolean ? "#t" : "#f"
        case let .output(output):
            return ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        }
    }

    func dictionaryItem(
        key: String,
        value: CompiledValue.Value,
        expectedType: ValueType
    ) -> [String: Any] {
        dictionaryItem(
            keyToken: ShortcutPlist.textTokenString(key),
            value: value,
            expectedType: expectedType
        )
    }

    /// One `WFDictionaryFieldValueItems` entry. `WFItemType` is WorkflowKit's
    /// own numbering - 0 text, 1 dictionary, 2 array, 3 number - and a list or
    /// dictionary value must use its own item type: through a text field
    /// Shortcuts flattens a list to newline-joined text and a dictionary to
    /// JSON. Booleans stay text because Longway represents them as `#t`/`#f`
    /// rather than as Shortcuts Booleans.
    func dictionaryItem(
        keyToken: [String: Any],
        value: CompiledValue.Value,
        expectedType: ValueType
    ) -> [String: Any] {
        switch expectedType == .any ? value.type : expectedType {
        case .list:
            guard case let .output(output) = value else {
                preconditionFailure("a list value is always an action output")
            }
            return [
                "WFItemType": 2,
                "WFKey": keyToken,
                "WFValue": ShortcutPlist.arrayParameterState(name: output.name, uuid: output.uuid)
            ]
        case .dictionary:
            guard case let .output(output) = value else {
                preconditionFailure("a dictionary value is always an action output")
            }
            return [
                "WFItemType": 1,
                "WFKey": keyToken,
                "WFValue": ShortcutPlist.dictionaryParameterState(name: output.name, uuid: output.uuid)
            ]
        case let valueType:
            return [
                "WFItemType": valueType == .number ? 3 : 0,
                "WFKey": keyToken,
                "WFValue": dictionaryValue(value)
            ]
        }
    }

    func dictionaryValue(_ value: CompiledValue.Value) -> [String: Any] {
        switch value {
        case let .literalString(string):
            ShortcutPlist.textTokenString(string)
        case let .literalNumber(number):
            ShortcutPlist.textTokenString(ShortcutPlist.formatNumber(number))
        case let .literalBoolean(boolean):
            ShortcutPlist.textTokenString(boolean ? "#t" : "#f")
        case let .output(output):
            ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        }
    }
}
