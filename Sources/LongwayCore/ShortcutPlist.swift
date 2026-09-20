import Foundation

/// Stateless builders for the raw Shortcuts property-list shapes.
/// Kept free of any compiler/type-inference model so it can be reused (and tested)
/// independently as the action catalog and value types grow.
enum ShortcutPlist {
    static func action(
        _ identifier: String,
        parameters: [String: Any] = [:],
        uuid: String? = UUID().uuidString
    ) -> [String: Any] {
        var actionParameters = parameters
        if let uuid {
            actionParameters["UUID"] = uuid
        }
        return [
            "WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": actionParameters
        ]
    }

    static func textTokenString(_ string: String) -> [String: Any] {
        [
            "Value": [
                "attachmentsByRange": [String: Any](),
                "string": string
            ],
            "WFSerializationType": "WFTextTokenString"
        ]
    }

    static func actionOutputTokenString(name: String, uuid: String) -> [String: Any] {
        [
            "Value": [
                "attachmentsByRange": ["{0, 1}": actionOutputValue(name: name, uuid: uuid)],
                "string": "\u{FFFC}"
            ],
            "WFSerializationType": "WFTextTokenString"
        ]
    }

    static func actionOutputAttachment(name: String, uuid: String) -> [String: Any] {
        [
            "Value": actionOutputValue(name: name, uuid: uuid),
            "WFSerializationType": "WFTextTokenAttachment"
        ]
    }

    static func namedVariableAttachment(name: String) -> [String: Any] {
        [
            "Value": ["VariableName": name, "Type": "Variable"],
            "WFSerializationType": "WFTextTokenAttachment"
        ]
    }

    /// The `WFItems` parameter of a Dictionary action, and the value of a
    /// dictionary-typed field inside one.
    static func dictionaryFieldValue(items: [[String: Any]]) -> [String: Any] {
        [
            "Value": ["WFDictionaryFieldValueItems": items],
            "WFSerializationType": "WFDictionaryFieldValue"
        ]
    }

    /// A dictionary field whose whole array value is one variable. Shortcuts
    /// writes the array-typed field (`WFItemType` 2) as an
    /// `WFArraySubstitutableParameterState` wrapping the variable attachment,
    /// rather than as a list of individual items.
    static func arrayParameterState(name: String, uuid: String) -> [String: Any] {
        [
            "Value": actionOutputAttachment(name: name, uuid: uuid),
            "WFSerializationType": "WFArraySubstitutableParameterState"
        ]
    }

    /// The same whole-field substitution for a dictionary-typed field
    /// (`WFItemType` 1). WorkflowKit pairs each item type with the parameter
    /// state class it substitutes a variable through, and names the serialized
    /// form after that class, exactly as the array case does.
    static func dictionaryParameterState(name: String, uuid: String) -> [String: Any] {
        [
            "Value": actionOutputAttachment(name: name, uuid: uuid),
            "WFSerializationType": "WFDictionarySubstitutableParameterState"
        ]
    }

    static func shortcutInputAttachment() -> [String: Any] {
        [
            "Value": ["Type": "ExtensionInput"],
            "WFSerializationType": "WFTextTokenAttachment"
        ]
    }

    static func conditionalInput(name: String, uuid: String) -> [String: Any] {
        [
            "Type": "Variable",
            "Variable": actionOutputAttachment(name: name, uuid: uuid)
        ]
    }

    static func formatNumber(_ number: Double) -> String {
        let description = String(number)
        return description.hasSuffix(".0") ? String(description.dropLast(2)) : description
    }

    private static func actionOutputValue(name: String, uuid: String) -> [String: Any] {
        [
            "OutputName": name,
            "OutputUUID": uuid,
            "Type": "ActionOutput"
        ]
    }
}
