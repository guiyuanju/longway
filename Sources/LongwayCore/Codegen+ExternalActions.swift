import Foundation

struct CompiledExternalAction {
    let actions: [[String: Any]]
    let value: CompiledValue.Value?
}

extension FunctionCompiler {
    func compileExternalAction(
        _ definition: ExternalActionDefinition,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledExternalAction {
        try requireArgumentCount(
            definition.arguments.count,
            action: definition.name,
            arguments: operands,
            at: location
        )

        var actions: [[String: Any]] = []
        var arguments: [String: CompiledValue.Value] = [:]
        for (index, pair) in zip(operands, definition.arguments).enumerated() {
            let compiled = try compileValue(pair.0, environment: environment)
            guard typesAreCompatible(compiled.value.type, pair.1.type) else {
                throw LongwayError(
                    "\(definition.name) argument \(index + 1) expects \(pair.1.type.name)",
                    at: pair.0.location
                )
            }
            actions.append(contentsOf: compiled.actions)
            arguments[pair.1.name] = compiled.value
        }

        let actionUUID = UUID().uuidString
        let rendered = try renderExternalTemplate(
            definition.template,
            actionName: definition.name,
            actionUUID: actionUUID,
            arguments: arguments,
            actions: &actions,
            at: location
        )
        guard let action = rendered as? [String: Any] else {
            throw LongwayError("external action '\(definition.name)' template did not render an action", at: location)
        }
        actions.append(action)

        guard let result = definition.result else {
            return CompiledExternalAction(actions: actions, value: nil)
        }
        return CompiledExternalAction(
            actions: actions,
            value: .output(ActionOutputReference(
                type: result.type,
                name: result.outputName,
                uuid: actionUUID,
                isRuntimeTyped: result.isRuntimeTyped
            ))
        )
    }

    private func renderExternalTemplate(
        _ template: JSONValue,
        actionName: String,
        actionUUID: String,
        arguments: [String: CompiledValue.Value],
        actions: inout [[String: Any]],
        at location: SourceLocation
    ) throws -> Any {
        switch template {
        case let .object(object):
            if let marker = object["$longway"]?.stringValue {
                if marker == "uuid" {
                    return actionUUID
                }
                let name = object["name"]!.stringValue!
                let value = arguments[name]!
                switch ArgumentEncoding(rawValue: object["encoding"]!.stringValue!)! {
                case .textToken:
                    return tokenString(value)
                case .attachment:
                    let output = materialize(value, into: &actions)
                    return ShortcutPlist.actionOutputAttachment(name: output.name, uuid: output.uuid)
                case .literal:
                    return try externalLiteral(value, actionName: actionName, argumentName: name, at: location)
                case .number:
                    return numberParameter(value)
                case .appEntity:
                    let identifier = try externalLiteral(
                        value,
                        actionName: actionName,
                        argumentName: name,
                        at: location
                    ) as! String
                    return [
                        "identifier": identifier,
                        "subtitle": ["key": identifier],
                        "title": ["key": identifier]
                    ]
                }
            }
            return try object.mapValues {
                try renderExternalTemplate(
                    $0,
                    actionName: actionName,
                    actionUUID: actionUUID,
                    arguments: arguments,
                    actions: &actions,
                    at: location
                )
            }
        case let .array(array):
            return try array.map {
                try renderExternalTemplate(
                    $0,
                    actionName: actionName,
                    actionUUID: actionUUID,
                    arguments: arguments,
                    actions: &actions,
                    at: location
                )
            }
        case let .string(value):
            return value
        case let .integer(value):
            return value
        case let .number(value):
            return value
        case let .boolean(value):
            return value
        case .null:
            preconditionFailure("catalog validation rejected null")
        }
    }

    private func externalLiteral(
        _ value: CompiledValue.Value,
        actionName: String,
        argumentName: String,
        at location: SourceLocation
    ) throws -> Any {
        switch value {
        case let .literalString(text):
            return text
        case let .literalNumber(number):
            return number
        case let .literalBoolean(boolean):
            return boolean
        case .output:
            throw LongwayError(
                "\(actionName) argument '\(argumentName)' must be a literal",
                at: location
            )
        }
    }
}
