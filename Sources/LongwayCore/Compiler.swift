import Foundation

public struct CompiledShortcut: Sendable {
    public let name: String
    public let data: Data
    public let actionCount: Int

    public init(name: String, data: Data, actionCount: Int) {
        self.name = name
        self.data = data
        self.actionCount = actionCount
    }
}

public struct LongwayCompiler {
    public init() {}

    public func compile(_ source: String, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> CompiledShortcut {
        var lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens: tokens)
        let program = try parser.parseProgram()
        let workflow = try compileProgram(program)

        let data = try PropertyListSerialization.data(
            fromPropertyList: workflow.propertyList,
            format: format,
            options: 0
        )
        return CompiledShortcut(name: workflow.name, data: data, actionCount: workflow.actions.count)
    }

    private func compileProgram(_ expression: Expression) throws -> Workflow {
        guard case let .list(forms) = expression.value else {
            throw LongwayError("program must be a (shortcut ...) form", at: expression.location)
        }
        guard !forms.isEmpty, forms[0].symbol == "shortcut" else {
            throw LongwayError("program must start with 'shortcut'", at: forms.first?.location ?? expression.location)
        }
        guard forms.count >= 2 else {
            throw LongwayError("shortcut expects a name", at: expression.location)
        }
        guard case let .string(name) = forms[1].value else {
            throw LongwayError("shortcut name must be a string", at: forms[1].location)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LongwayError("shortcut name cannot be empty", at: forms[1].location)
        }

        var actions: [[String: Any]] = []
        for form in forms.dropFirst(2) {
            actions.append(contentsOf: try compileForm(form, environment: [:]))
        }
        guard !actions.isEmpty else {
            throw LongwayError("shortcut must contain at least one action", at: expression.location)
        }

        return Workflow(name: name, actions: actions)
    }

    private func compileForm(
        _ expression: Expression,
        environment: [String: ActionOutputReference]
    ) throws -> [[String: Any]] {
        guard case let .list(parts) = expression.value, let head = parts.first else {
            throw LongwayError("expected an action form", at: expression.location)
        }
        guard case let .symbol(formName) = head.value else {
            throw LongwayError("action name must be a symbol", at: head.location)
        }

        if formName == "let" {
            return try compileLet(parts: parts, at: expression.location, environment: environment)
        }
        return try compileAction(
            formName,
            arguments: Array(parts.dropFirst()),
            at: expression.location,
            nameLocation: head.location,
            environment: environment
        )
    }

    private func compileLet(
        parts: [Expression],
        at location: SourceLocation,
        environment: [String: ActionOutputReference]
    ) throws -> [[String: Any]] {
        guard parts.count >= 3 else {
            throw LongwayError("let expects bindings and at least one body form", at: location)
        }
        guard case let .list(bindings) = parts[1].value else {
            throw LongwayError("let bindings must be a list", at: parts[1].location)
        }

        var actions: [[String: Any]] = []
        var localBindings: [String: ActionOutputReference] = [:]
        var bindingNames = Set<String>()

        for binding in bindings {
            guard case let .list(pair) = binding.value, pair.count == 2 else {
                throw LongwayError("let binding must contain a name and value", at: binding.location)
            }
            guard case let .symbol(name) = pair[0].value else {
                throw LongwayError("let binding name must be a symbol", at: pair[0].location)
            }
            guard bindingNames.insert(name).inserted else {
                throw LongwayError("duplicate let binding '\(name)'", at: pair[0].location)
            }

            let compiledValue = try compileValue(pair[1], environment: environment)
            actions.append(contentsOf: compiledValue.actions)
            localBindings[name] = materialize(compiledValue.value, into: &actions)
        }

        var bodyEnvironment = environment
        bodyEnvironment.merge(localBindings) { _, local in local }
        for bodyForm in parts.dropFirst(2) {
            actions.append(contentsOf: try compileForm(bodyForm, environment: bodyEnvironment))
        }
        return actions
    }

    private func compileAction(
        _ actionName: String,
        arguments: [Expression],
        at location: SourceLocation,
        nameLocation: SourceLocation,
        environment: [String: ActionOutputReference]
    ) throws -> [[String: Any]] {
        switch actionName {
        case "show-result":
            try requireArgumentCount(1, action: actionName, arguments: arguments, at: location)
            let compiledValue = try compileValue(arguments[0], environment: environment)
            let text: [String: Any]
            switch compiledValue.value {
            case let .literalString(value):
                text = textTokenString(value)
            case let .literalNumber(value):
                text = textTokenString(formatNumber(value))
            case let .output(output):
                text = actionOutputTokenString(output)
            }
            return compiledValue.actions + [
                action("is.workflow.actions.showresult", parameters: ["Text": text], uuid: nil)
            ]

        case "notification":
            let value = try stringArgument(actionName, arguments: arguments, at: location)
            return [action("is.workflow.actions.notification", parameters: [
                "WFNotificationActionBody": value,
                "WFNotificationActionSound": true
            ])]

        case "open-url":
            let value = try stringArgument(actionName, arguments: arguments, at: location)
            guard let url = URL(string: value), url.scheme != nil else {
                throw LongwayError("open-url expects an absolute URL", at: arguments[0].location)
            }
            return [
                action("is.workflow.actions.url", parameters: ["WFURLActionURL": value]),
                action("is.workflow.actions.openurl")
            ]

        case "wait":
            try requireArgumentCount(1, action: actionName, arguments: arguments, at: location)
            guard case let .number(seconds) = arguments[0].value else {
                throw LongwayError("wait expects a number", at: arguments[0].location)
            }
            guard seconds.isFinite else {
                throw LongwayError("wait duration must be finite", at: arguments[0].location)
            }
            guard seconds >= 0 else {
                throw LongwayError("wait duration cannot be negative", at: arguments[0].location)
            }
            return [action("is.workflow.actions.delay", parameters: ["WFDelayTime": seconds])]

        default:
            throw LongwayError("unknown action '\(actionName)'", at: nameLocation)
        }
    }

    private func compileValue(
        _ expression: Expression,
        environment: [String: ActionOutputReference]
    ) throws -> CompiledValue {
        switch expression.value {
        case let .string(value):
            return CompiledValue(actions: [], value: .literalString(value))

        case let .number(value):
            guard value.isFinite else {
                throw LongwayError("number must be finite", at: expression.location)
            }
            return CompiledValue(actions: [], value: .literalNumber(value))

        case let .symbol(name):
            guard let output = environment[name] else {
                throw LongwayError("unknown variable '\(name)'", at: expression.location)
            }
            return CompiledValue(actions: [], value: .output(output))

        case let .list(parts):
            guard let head = parts.first, case let .symbol(operation) = head.value else {
                throw LongwayError("expected a value expression", at: expression.location)
            }
            guard let shortcutOperation = mathOperation(operation) else {
                throw LongwayError("unknown value form '\(operation)'", at: head.location)
            }
            return try compileMath(
                operation,
                shortcutOperation: shortcutOperation,
                operands: Array(parts.dropFirst()),
                at: expression.location,
                environment: environment
            )

        case .boolean:
            throw LongwayError("unsupported value type", at: expression.location)
        }
    }

    private func compileMath(
        _ operation: String,
        shortcutOperation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: [String: ActionOutputReference]
    ) throws -> CompiledValue {
        guard operands.count >= 2 else {
            throw LongwayError("\(operation) expects at least 2 operands, got \(operands.count)", at: location)
        }

        let first = try compileValue(operands[0], environment: environment)
        guard first.value.type == .number else {
            throw LongwayError("\(operation) expects number operands", at: operands[0].location)
        }

        var actions = first.actions
        var result = materializeNumber(first.value, into: &actions)

        for operand in operands.dropFirst() {
            let compiledOperand = try compileValue(operand, environment: environment)
            guard compiledOperand.value.type == .number else {
                throw LongwayError("\(operation) expects number operands", at: operand.location)
            }
            actions.append(contentsOf: compiledOperand.actions)

            let uuid = UUID().uuidString
            actions.append(action("is.workflow.actions.math", parameters: [
                "WFInput": actionOutputAttachment(result),
                "WFMathOperation": shortcutOperation,
                "WFMathOperand": numberParameter(compiledOperand.value)
            ], uuid: uuid))
            result = ActionOutputReference(type: .number, name: "Calculation Result", uuid: uuid)
        }

        return CompiledValue(actions: actions, value: .output(result))
    }

    private func materialize(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalString(text):
            let uuid = UUID().uuidString
            actions.append(action("is.workflow.actions.gettext", parameters: [
                "WFTextActionText": textTokenString(text)
            ], uuid: uuid))
            return ActionOutputReference(type: .text, name: "Text", uuid: uuid)

        case .literalNumber:
            return materializeNumber(value, into: &actions)

        case let .output(output):
            return output
        }
    }

    private func materializeNumber(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalNumber(number):
            let uuid = UUID().uuidString
            actions.append(action("is.workflow.actions.number", parameters: [
                "WFNumberActionNumber": number
            ], uuid: uuid))
            return ActionOutputReference(type: .number, name: "Number", uuid: uuid)

        case let .output(output):
            precondition(output.type == .number)
            return output

        case .literalString:
            preconditionFailure("text cannot be materialized as a number")
        }
    }

    private func numberParameter(_ value: CompiledValue.Value) -> Any {
        switch value {
        case let .literalNumber(number):
            return number
        case let .output(output):
            return actionOutputAttachment(output)
        case .literalString:
            preconditionFailure("text cannot be used as a number parameter")
        }
    }

    private func mathOperation(_ symbol: String) -> String? {
        switch symbol {
        case "+": "+"
        case "-": "-"
        case "*": "×"
        case "/": "÷"
        default: nil
        }
    }

    private func formatNumber(_ number: Double) -> String {
        let description = String(number)
        return description.hasSuffix(".0") ? String(description.dropLast(2)) : description
    }

    private func stringArgument(
        _ action: String,
        arguments: [Expression],
        at location: SourceLocation
    ) throws -> String {
        try requireArgumentCount(1, action: action, arguments: arguments, at: location)
        guard case let .string(value) = arguments[0].value else {
            throw LongwayError("\(action) expects a string", at: arguments[0].location)
        }
        return value
    }

    private func requireArgumentCount(
        _ count: Int,
        action: String,
        arguments: [Expression],
        at location: SourceLocation
    ) throws {
        guard arguments.count == count else {
            let noun = count == 1 ? "argument" : "arguments"
            throw LongwayError("\(action) expects \(count) \(noun), got \(arguments.count)", at: location)
        }
    }

    private func textTokenString(_ string: String) -> [String: Any] {
        [
            "Value": [
                "attachmentsByRange": [String: Any](),
                "string": string
            ],
            "WFSerializationType": "WFTextTokenString"
        ]
    }

    private func actionOutputTokenString(_ output: ActionOutputReference) -> [String: Any] {
        [
            "Value": [
                "attachmentsByRange": ["{0, 1}": actionOutputValue(output)],
                "string": "\u{FFFC}"
            ],
            "WFSerializationType": "WFTextTokenString"
        ]
    }

    private func actionOutputAttachment(_ output: ActionOutputReference) -> [String: Any] {
        [
            "Value": actionOutputValue(output),
            "WFSerializationType": "WFTextTokenAttachment"
        ]
    }

    private func actionOutputValue(_ output: ActionOutputReference) -> [String: Any] {
        [
            "OutputName": output.name,
            "OutputUUID": output.uuid,
            "Type": "ActionOutput"
        ]
    }

    private func action(
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
}

private enum ValueType {
    case text
    case number
}

private struct ActionOutputReference {
    let type: ValueType
    let name: String
    let uuid: String
}

private struct CompiledValue {
    let actions: [[String: Any]]
    let value: Value

    enum Value {
        case literalString(String)
        case literalNumber(Double)
        case output(ActionOutputReference)

        var type: ValueType {
            switch self {
            case .literalString:
                .text
            case .literalNumber:
                .number
            case let .output(output):
                output.type
            }
        }
    }
}

private struct Workflow {
    let name: String
    let actions: [[String: Any]]

    var propertyList: [String: Any] {
        [
            "WFWorkflowActions": actions,
            "WFWorkflowClientRelease": "3.0",
            "WFWorkflowClientVersion": "1200",
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowIcon": [
                "WFWorkflowIconGlyphNumber": 59511,
                "WFWorkflowIconStartColor": 4282601983
            ],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowInputContentItemClasses": ["WFGenericFileContentItem"],
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
            "WFWorkflowTypes": []
        ]
    }
}

private extension Expression {
    var symbol: String? {
        guard case let .symbol(value) = self.value else { return nil }
        return value
    }
}
