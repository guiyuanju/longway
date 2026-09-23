import Foundation

/// Turns a `CompiledValue.Value` into a referenceable action output, or into the
/// raw plist shape a particular consumer (dictionary item, output parameter,
/// math operand, …) expects.
///
/// Two families do the referencing. `materialize*` reuses an action output that
/// Shortcuts already produces with the wanted runtime type, and only emits an
/// action when it has to. `emit*` always emits, which callers need when
/// Shortcuts must see a definitely-typed producer action - a conditional
/// branch's result, or a tail-loop variable.
extension FunctionCompiler {
    /// The token string every Shortcuts text-shaped field accepts: a literal,
    /// or a reference to another action's output. Booleans travel as the text
    /// `#t`/`#f`, which is how Longway represents them throughout.
    func tokenString(_ value: CompiledValue.Value) -> [String: Any] {
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

    /// Makes `value` referenceable by UUID without changing its type. An action
    /// output already is one.
    func materialize(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .output(output):
            return output
        case .literalString:
            return emitText(tokenString(value), type: .text, into: &actions)
        case .literalNumber:
            return materializeNumber(value, into: &actions)
        case .literalBoolean:
            return materializeBoolean(value, into: &actions)
        }
    }

    func materializeNumber(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        reuseRuntimeTyped(value, as: .number) ?? emitNumber(value, into: &actions)
    }

    func materializeBoolean(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        reuseRuntimeTyped(value, as: .boolean) ?? emitBoolean(value, into: &actions)
    }

    /// An action output that Shortcuts already produces with `type` needs no
    /// coercing action; it only needs to be re-labelled with that type.
    private func reuseRuntimeTyped(
        _ value: CompiledValue.Value,
        as type: ValueType
    ) -> ActionOutputReference? {
        guard case let .output(output) = value, output.isRuntimeTyped else { return nil }
        precondition(typesAreCompatible(output.type, type))
        return ActionOutputReference(type: type, name: output.name, uuid: output.uuid)
    }

    /// Re-publishes `value` through a fresh action of its own type. Text,
    /// numbers, and Booleans get a producer action that fixes their runtime
    /// type; everything else goes through Get Variable, which carries the
    /// runtime value across unchanged - passing a list or a dictionary through
    /// Text or Number would flatten it to newline-joined text or to JSON.
    func emitValue(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value.type {
        case .text:
            return emitText(tokenString(value), type: .text, into: &actions)
        case .number:
            return emitNumber(value, into: &actions)
        case .boolean:
            return emitBoolean(value, into: &actions)
        case .list, .dictionary, .any:
            guard case let .output(output) = value else {
                preconditionFailure("a list, dictionary, or generic value is always an action output")
            }
            let name = switch value.type {
            case .list: "List"
            case .dictionary: "Dictionary"
            default: "Value"
            }
            return emitPassthrough(output, type: value.type, name: name, into: &actions)
        }
    }

    func emitBoolean(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        precondition(typesAreCompatible(value.type, .boolean))
        return emitText(tokenString(value), type: .boolean, into: &actions)
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
    /// one attachment filling the whole token string. A bare number literal is
    /// published through a Number action first so the workflow returns a real
    /// number rather than its text.
    func outputParameter(
        _ value: CompiledValue.Value,
        actions: inout [[String: Any]]
    ) -> [String: Any] {
        guard case .literalNumber = value else { return tokenString(value) }
        return tokenString(.output(emitNumber(value, into: &actions)))
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
        case .output:
            return tokenString(value)
        }
    }

    /// One `WFDictionaryFieldValueItems` entry. `WFItemType` is WorkflowKit's
    /// own numbering - 0 text, 1 dictionary, 2 array, 3 number - and a list or
    /// dictionary value must use its own item type: through a text field
    /// Shortcuts flattens a list to newline-joined text and a dictionary to
    /// JSON. Booleans stay text because Longway represents them as `#t`/`#f`
    /// rather than as Shortcuts Booleans.
    func dictionaryItem(
        key: CompiledValue.Value,
        value: CompiledValue.Value,
        expectedType: ValueType
    ) -> [String: Any] {
        let keyToken = tokenString(key)
        switch expectedType == .any ? value.type : expectedType {
        case .list, .dictionary:
            guard case let .output(output) = value else {
                preconditionFailure("a list or dictionary value is always an action output")
            }
            let isList = (expectedType == .any ? value.type : expectedType) == .list
            return [
                "WFItemType": isList ? 2 : 1,
                "WFKey": keyToken,
                "WFValue": isList
                    ? ShortcutPlist.arrayParameterState(name: output.name, uuid: output.uuid)
                    : ShortcutPlist.dictionaryParameterState(name: output.name, uuid: output.uuid)
            ]
        case let valueType:
            return [
                "WFItemType": valueType == .number ? 3 : 0,
                "WFKey": keyToken,
                "WFValue": tokenString(value)
            ]
        }
    }
}
