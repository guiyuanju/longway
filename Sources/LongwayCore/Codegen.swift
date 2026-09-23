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
    let catalog: ActionCatalog

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
        if isTailRecursive(definition, additionalSideEffectingForms: catalog.sideEffectingNames) {
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

        if formName == "let" || formName == "let*" {
            return try compileLet(parts: parts, at: expression.location, environment: environment)
        }
        if formName == "if" {
            return try compileIfForm(
                arguments: Array(parts.dropFirst()),
                at: expression.location,
                environment: environment
            )
        }
        if let externalAction = catalog.actions[formName] {
            return try compileExternalAction(
                externalAction,
                operands: Array(parts.dropFirst()),
                at: expression.location,
                environment: environment
            ).actions
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
            if formName == "let" || formName == "let*" {
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
        let form = try LetForm(parts, at: location)
        var actions: [[String: Any]] = []
        var bodyEnvironment = environment
        var localBindings: [String: ActionOutputReference] = [:]

        for binding in form.bindings {
            // A `let` initializer sees the outer scope; a `let*` initializer
            // sees the bindings before it.
            let initializerEnvironment = form.isSequential ? bodyEnvironment : environment
            let compiledValue = try compileValue(binding.value, environment: initializerEnvironment)
            actions.append(contentsOf: compiledValue.actions)
            let output = materialize(compiledValue.value, into: &actions)
            if form.isSequential {
                bodyEnvironment.variables[binding.name] = output
            } else {
                localBindings[binding.name] = output
            }
        }

        bodyEnvironment.variables.merge(localBindings) { _, local in local }
        return (actions, bodyEnvironment)
    }

    /// Source forms that run a Shortcuts action for its effect rather than for
    /// a value. Add new effect-only Shortcuts actions here.
    func compileAction(
        _ actionName: String,
        arguments: [Expression],
        at location: SourceLocation,
        nameLocation: SourceLocation,
        environment: CompileEnvironment
    ) throws -> [[String: Any]] {
        switch actionName {
        case "show-result":
            try requireArgumentCount(1, action: actionName, arguments: arguments, at: location)
            let compiledValue = try compileValue(arguments[0], environment: environment)
            return compiledValue.actions + showResultAction(compiledValue.value)

        case "notification":
            let value = try stringArgument(actionName, arguments: arguments, at: location)
            return [ShortcutPlist.action("is.workflow.actions.notification", parameters: [
                "WFNotificationActionBody": value,
                "WFNotificationActionSound": true
            ])]

        case "open-url":
            let value = try stringArgument(actionName, arguments: arguments, at: location)
            guard let url = URL(string: value), url.scheme != nil else {
                throw LongwayError("open-url expects an absolute URL", at: arguments[0].location)
            }
            return [
                ShortcutPlist.action("is.workflow.actions.url", parameters: ["WFURLActionURL": value]),
                ShortcutPlist.action("is.workflow.actions.openurl")
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
            return [ShortcutPlist.action("is.workflow.actions.delay", parameters: ["WFDelayTime": seconds])]

        default:
            throw LongwayError("unknown action '\(actionName)'", at: nameLocation)
        }
    }

    func showResultAction(_ value: CompiledValue.Value) -> [[String: Any]] {
        [ShortcutPlist.action(
            "is.workflow.actions.showresult",
            parameters: ["Text": tokenString(value)],
            uuid: nil
        )]
    }

    func stringArgument(
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
}
