import Foundation

public struct ActionCatalog: Sendable {
    public static let empty = ActionCatalog(actions: [:])

    let actions: [String: ExternalActionDefinition]

    public var actionNames: Set<String> { Set(actions.keys) }

    var sideEffectingNames: Set<String> {
        Set(actions.values.lazy.filter(\.sideEffect).map(\.name))
    }

    public init(contentsOf urls: [URL]) throws {
        var definitions: [String: ExternalActionDefinition] = [:]
        for url in urls {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ActionCatalogError("cannot read action catalog \(url.path): \(error.localizedDescription)")
            }
            let catalog = try ActionCatalog(data: data, source: url.path)
            for (name, definition) in catalog.actions {
                guard definitions[name] == nil else {
                    throw ActionCatalogError("duplicate external action '\(name)' in \(url.path)")
                }
                definitions[name] = definition
            }
        }
        self.actions = definitions
    }

    public init(data: Data, source: String = "action catalog") throws {
        let document: CatalogDocument
        do {
            document = try JSONDecoder().decode(CatalogDocument.self, from: data)
        } catch {
            throw ActionCatalogError("cannot decode \(source): \(error.localizedDescription)")
        }
        guard document.version == 1 else {
            throw ActionCatalogError("\(source) uses unsupported catalog version \(document.version)")
        }

        var definitions: [String: ExternalActionDefinition] = [:]
        for entry in document.actions {
            let definition = try ExternalActionDefinition(entry, source: source)
            guard !builtinFormNames.contains(definition.name) else {
                throw ActionCatalogError("external action '\(definition.name)' conflicts with a built-in form")
            }
            guard definitions[definition.name] == nil else {
                throw ActionCatalogError("duplicate external action '\(definition.name)' in \(source)")
            }
            definitions[definition.name] = definition
        }
        self.actions = definitions
    }

    private init(actions: [String: ExternalActionDefinition]) {
        self.actions = actions
    }
}

struct ExternalActionDefinition: Sendable {
    let name: String
    let arguments: [ExternalActionArgument]
    let result: ExternalActionResult?
    let sideEffect: Bool
    let template: JSONValue

    fileprivate init(_ entry: CatalogAction, source: String) throws {
        let identifierPattern = "^[A-Za-z_][A-Za-z0-9_-]*$"
        guard entry.name.range(of: identifierPattern, options: .regularExpression) != nil else {
            throw ActionCatalogError("invalid external action name '\(entry.name)' in \(source)")
        }

        var names = Set<String>()
        var arguments: [ExternalActionArgument] = []
        for argument in entry.arguments {
            guard argument.name.range(of: identifierPattern, options: .regularExpression) != nil else {
                throw ActionCatalogError("invalid argument name '\(argument.name)' for external action '\(entry.name)'")
            }
            guard names.insert(argument.name).inserted else {
                throw ActionCatalogError("duplicate argument '\(argument.name)' for external action '\(entry.name)'")
            }
            arguments.append(ExternalActionArgument(
                name: argument.name,
                type: try ValueType(catalogName: argument.type, context: "argument '\(argument.name)' of '\(entry.name)'")
            ))
        }

        let result = try entry.result.map {
            guard !$0.outputName.isEmpty else {
                throw ActionCatalogError("external action '\(entry.name)' has an empty result outputName")
            }
            return ExternalActionResult(
                type: try ValueType(catalogName: $0.type, context: "result of '\(entry.name)'"),
                outputName: $0.outputName,
                isRuntimeTyped: $0.runtimeTyped ?? false
            )
        }

        guard case let .object(root) = entry.template,
              root["WFWorkflowActionIdentifier"]?.stringValue != nil,
              case let .object(parameters)? = root["WFWorkflowActionParameters"],
              parameters["UUID"] == .object(["$longway": .string("uuid")])
        else {
            throw ActionCatalogError(
                "external action '\(entry.name)' template must contain an action identifier and a generated UUID placeholder"
            )
        }

        var referencedArguments = Set<String>()
        try entry.template.validatePlaceholders(
            actionName: entry.name,
            argumentTypes: Dictionary(uniqueKeysWithValues: arguments.map { ($0.name, $0.type) }),
            referencedArguments: &referencedArguments
        )
        let unused = names.subtracting(referencedArguments).sorted()
        guard unused.isEmpty else {
            throw ActionCatalogError("external action '\(entry.name)' has unused arguments: \(unused.joined(separator: ", "))")
        }

        self.name = entry.name
        self.arguments = arguments
        self.result = result
        self.sideEffect = entry.sideEffect ?? true
        self.template = entry.template
    }
}

struct ExternalActionArgument: Sendable {
    let name: String
    let type: ValueType
}

struct ExternalActionResult: Sendable {
    let type: ValueType
    let outputName: String
    let isRuntimeTyped: Bool
}

private struct CatalogDocument: Decodable {
    let version: Int
    let actions: [CatalogAction]
}

private struct CatalogAction: Decodable {
    let name: String
    let arguments: [CatalogArgument]
    let result: CatalogResult?
    let sideEffect: Bool?
    let template: JSONValue
}

private struct CatalogArgument: Decodable {
    let name: String
    let type: String
}

private struct CatalogResult: Decodable {
    let type: String
    let outputName: String
    let runtimeTyped: Bool?
}

indirect enum JSONValue: Decodable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    func validatePlaceholders(
        actionName: String,
        argumentTypes: [String: ValueType],
        referencedArguments: inout Set<String>
    ) throws {
        switch self {
        case let .object(object):
            if let marker = object["$longway"]?.stringValue {
                switch marker {
                case "uuid":
                    guard object.count == 1 else {
                        throw ActionCatalogError("uuid placeholder in '\(actionName)' cannot contain other fields")
                    }
                case "argument":
                    guard let name = object["name"]?.stringValue,
                          let encoding = object["encoding"]?.stringValue,
                          object.count == 3
                    else {
                        throw ActionCatalogError("argument placeholder in '\(actionName)' requires name and encoding")
                    }
                    guard let argumentType = argumentTypes[name] else {
                        throw ActionCatalogError("template for '\(actionName)' references unknown argument '\(name)'")
                    }
                    guard ["text-token", "attachment", "literal", "number", "app-entity"].contains(encoding) else {
                        throw ActionCatalogError("argument '\(name)' of '\(actionName)' uses unsupported encoding '\(encoding)'")
                    }
                    guard encoding != "number" || argumentType == .number else {
                        throw ActionCatalogError("number encoding requires argument '\(name)' of '\(actionName)' to have number type")
                    }
                    guard encoding != "text-token" || (argumentType != .list && argumentType != .dictionary) else {
                        throw ActionCatalogError("text-token encoding cannot carry \(argumentType.pluralName) for argument '\(name)' of '\(actionName)'")
                    }
                    guard encoding != "app-entity" || argumentType == .text else {
                        throw ActionCatalogError("app-entity encoding requires argument '\(name)' of '\(actionName)' to have text type")
                    }
                    referencedArguments.insert(name)
                default:
                    throw ActionCatalogError("template for '\(actionName)' contains unknown placeholder '\(marker)'")
                }
                return
            }
            for value in object.values {
                try value.validatePlaceholders(
                    actionName: actionName,
                    argumentTypes: argumentTypes,
                    referencedArguments: &referencedArguments
                )
            }
        case let .array(array):
            for value in array {
                try value.validatePlaceholders(
                    actionName: actionName,
                    argumentTypes: argumentTypes,
                    referencedArguments: &referencedArguments
                )
            }
        case .null:
            throw ActionCatalogError("template for '\(actionName)' contains null, which property lists do not support")
        case .string, .integer, .number, .boolean:
            break
        }
    }
}

private extension ValueType {
    init(catalogName: String, context: String) throws {
        switch catalogName {
        case "text": self = .text
        case "number": self = .number
        case "boolean": self = .boolean
        case "list": self = .list
        case "dictionary": self = .dictionary
        case "any": self = .any
        default: throw ActionCatalogError("unknown type '\(catalogName)' for \(context)")
        }
    }
}

public struct ActionCatalogError: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
