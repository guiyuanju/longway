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
