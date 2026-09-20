import Foundation

struct ActionOutputReference {
    let type: ValueType
    let name: String
    let uuid: String
    let isRuntimeTyped: Bool

    init(type: ValueType, name: String, uuid: String, isRuntimeTyped: Bool = true) {
        self.type = type
        self.name = name
        self.uuid = uuid
        self.isRuntimeTyped = isRuntimeTyped
    }
}

struct CompiledValue {
    let actions: [[String: Any]]
    let value: Value

    enum Value {
        case literalString(String)
        case literalNumber(Double)
        case literalBoolean(Bool)
        case output(ActionOutputReference)

        var type: ValueType {
            switch self {
            case .literalString:
                .text
            case .literalNumber:
                .number
            case .literalBoolean:
                .boolean
            case let .output(output):
                output.type
            }
        }
    }
}

struct CompileEnvironment {
    var variables: [String: ActionOutputReference]
}

struct Workflow {
    let name: String
    let actions: [[String: Any]]
    let acceptsInput: Bool
    let outputType: ValueType

    var propertyList: [String: Any] {
        [
            "WFWorkflowActions": actions,
            "WFWorkflowClientRelease": "3.0",
            "WFWorkflowClientVersion": "1200",
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": acceptsInput,
            "WFWorkflowIcon": [
                "WFWorkflowIconGlyphNumber": 59511,
                "WFWorkflowIconStartColor": 4282601983
            ],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowInputContentItemClasses": acceptsInput
                ? ["WFDictionaryContentItem"]
                : ["WFGenericFileContentItem"],
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowOutputContentItemClasses": outputContentItemClasses,
            "WFWorkflowTypes": []
        ]
    }

    private var outputContentItemClasses: [String] {
        switch outputType {
        case .text, .boolean:
            ["WFStringContentItem"]
        case .number:
            ["WFNumberContentItem"]
        case .dictionary:
            ["WFDictionaryContentItem"]
        case .list, .any:
            ["WFStringContentItem", "WFNumberContentItem", "WFGenericFileContentItem"]
        }
    }
}

/// Lowers one typed function definition into a standalone Shortcut's actions.
/// Split across `Codegen+*.swift` by concern: this file owns the per-definition
/// entry point plus `let`/body sequencing; see the other Codegen+ files for
/// the action catalog, value expressions, conditionals, and value materialization.
struct FunctionCompiler {
    let signatures: [String: FunctionSignature]

    func compile(_ definition: FunctionDefinition) throws -> Workflow {
        let signature = signatures[definition.name]!
        var actions: [[String: Any]] = []
        var variables: [String: ActionOutputReference] = [:]

        for parameter in signature.parameters {
            let uuid = UUID().uuidString
            actions.append(ShortcutPlist.action("is.workflow.actions.getvalueforkey", parameters: [
                "CustomOutputName": parameter.name,
                "WFDictionaryKey": parameter.name,
                "WFGetDictionaryValueType": "Value",
                "WFInput": ShortcutPlist.shortcutInputAttachment()
            ], uuid: uuid))
            variables[parameter.name] = ActionOutputReference(
                type: parameter.type,
                name: parameter.name,
                uuid: uuid,
                isRuntimeTyped: false
            )
        }

        let result: CompiledValue
        if isTailRecursive(definition) {
            result = try compileTailRecursiveLoop(definition, signature: signature, parameterOutputs: variables)
        } else {
            let environment = CompileEnvironment(variables: variables)
            for form in definition.body.dropLast() {
                actions.append(contentsOf: try compileForm(form, environment: environment))
            }
            result = try compileResultForm(definition.body.last!, environment: environment)
        }
        actions.append(contentsOf: result.actions)
        let output = outputParameter(result.value, actions: &actions)
        actions.append(ShortcutPlist.action("is.workflow.actions.output", parameters: [
            "WFOutput": output
        ]))

        return Workflow(
            name: definition.name,
            actions: actions,
            acceptsInput: !definition.parameters.isEmpty,
            outputType: signature.returnType
        )
    }

    func compileForm(
        _ expression: Expression,
        environment: CompileEnvironment
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
        if formName == "if" {
            return try compileIfForm(
                arguments: Array(parts.dropFirst()),
                at: expression.location,
                environment: environment
            )
        }
        if signatures[formName] != nil {
            return try compileValue(expression, environment: environment).actions
        }
        return try compileAction(
            formName,
            arguments: Array(parts.dropFirst()),
            at: expression.location,
            nameLocation: head.location,
            environment: environment
        )
    }

    func compileResultForm(
        _ expression: Expression,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        if case let .list(parts) = expression.value, let head = parts.first,
           case let .symbol(formName) = head.value {
            if formName == "let" {
                return try compileLetResult(parts: parts, at: expression.location, environment: environment)
            }
            if formName == "show-result" {
                let arguments = Array(parts.dropFirst())
                try requireArgumentCount(1, action: formName, arguments: arguments, at: expression.location)
                let result = try compileValue(arguments[0], environment: environment)
                return CompiledValue(
                    actions: result.actions + showResultAction(result.value),
                    value: result.value
                )
            }
        }
        return try compileValue(expression, environment: environment)
    }

    func compileLet(
        parts: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> [[String: Any]] {
        let prepared = try compileLetBindings(parts: parts, at: location, environment: environment)
        var actions = prepared.actions
        for bodyForm in parts.dropFirst(2) {
            actions.append(contentsOf: try compileForm(bodyForm, environment: prepared.environment))
        }
        return actions
    }

    func compileLetResult(
        parts: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        let prepared = try compileLetBindings(parts: parts, at: location, environment: environment)
        var actions = prepared.actions
        let body = Array(parts.dropFirst(2))
        for bodyForm in body.dropLast() {
            actions.append(contentsOf: try compileForm(bodyForm, environment: prepared.environment))
        }
        let result = try compileResultForm(body.last!, environment: prepared.environment)
        return CompiledValue(actions: actions + result.actions, value: result.value)
    }

    func compileLetBindings(
        parts: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> (actions: [[String: Any]], environment: CompileEnvironment) {
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
        bodyEnvironment.variables.merge(localBindings) { _, local in local }
        return (actions, bodyEnvironment)
    }
}
