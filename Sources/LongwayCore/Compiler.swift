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

public struct CompiledProgram: Sendable {
    public let shortcuts: [CompiledShortcut]

    public init(shortcuts: [CompiledShortcut]) {
        self.shortcuts = shortcuts
    }
}

public struct LongwayCompiler {
    public init() {}

    public func compileProgram(
        _ source: String,
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> CompiledProgram {
        var lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens: tokens)
        let expressions = try parser.parseProgram()
        let definitions = try parseDefinitions(expressions)
        let signatures = try inferSignatures(definitions)

        let shortcuts = try definitions.map { definition in
            let workflow = try compileDefinition(definition, signatures: signatures)
            let data = try PropertyListSerialization.data(
                fromPropertyList: workflow.propertyList,
                format: format,
                options: 0
            )
            return CompiledShortcut(
                name: workflow.name,
                data: data,
                actionCount: workflow.actions.count
            )
        }
        return CompiledProgram(shortcuts: shortcuts)
    }

    public func compile(
        _ source: String,
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> CompiledShortcut {
        let program = try compileProgram(source, format: format)
        guard program.shortcuts.count == 1, let shortcut = program.shortcuts.first else {
            throw LongwayError(
                "source defines \(program.shortcuts.count) functions; use compileProgram to compile all functions",
                at: SourceLocation(line: 1, column: 1)
            )
        }
        return shortcut
    }

    private func parseDefinitions(_ expressions: [Expression]) throws -> [FunctionDefinition] {
        guard !expressions.isEmpty else {
            throw LongwayError(
                "expected at least one function definition",
                at: SourceLocation(line: 1, column: 1)
            )
        }

        var definitions: [FunctionDefinition] = []
        var names = Set<String>()
        var artifactNames: [String: String] = [:]

        for expression in expressions {
            guard case let .list(forms) = expression.value,
                  forms.first?.symbol == "define"
            else {
                throw LongwayError("top-level forms must be function definitions", at: expression.location)
            }
            guard forms.count >= 3 else {
                throw LongwayError("define expects a signature and at least one body form", at: expression.location)
            }
            guard case let .list(signature) = forms[1].value, let nameExpression = signature.first,
                  case let .symbol(name) = nameExpression.value
            else {
                throw LongwayError("define signature must be a list beginning with a function name", at: forms[1].location)
            }
            guard !reservedFunctionNames.contains(name) else {
                throw LongwayError("function name '\(name)' is reserved", at: nameExpression.location)
            }
            try validateIdentifier(name, role: "function", at: nameExpression.location)
            guard names.insert(name).inserted else {
                throw LongwayError("duplicate function definition '\(name)'", at: nameExpression.location)
            }
            let artifactName = name.lowercased()
            if let conflictingName = artifactNames[artifactName] {
                throw LongwayError(
                    "function name '\(name)' conflicts with '\(conflictingName)' on case-insensitive file systems",
                    at: nameExpression.location
                )
            }
            artifactNames[artifactName] = name

            var parameters: [FunctionParameter] = []
            var parameterNames = Set<String>()
            for parameterExpression in signature.dropFirst() {
                guard case let .symbol(parameter) = parameterExpression.value else {
                    throw LongwayError("function parameters must be symbols", at: parameterExpression.location)
                }
                try validateIdentifier(parameter, role: "parameter", at: parameterExpression.location)
                guard parameterNames.insert(parameter).inserted else {
                    throw LongwayError("duplicate function parameter '\(parameter)'", at: parameterExpression.location)
                }
                parameters.append(FunctionParameter(name: parameter, location: parameterExpression.location))
            }
            definitions.append(FunctionDefinition(
                name: name,
                nameLocation: nameExpression.location,
                parameters: parameters,
                body: Array(forms.dropFirst(2)),
                location: expression.location
            ))
        }
        return definitions
    }

    private func validateIdentifier(
        _ identifier: String,
        role: String,
        at location: SourceLocation
    ) throws {
        let pattern = "^[A-Za-z_][A-Za-z0-9_-]*$"
        guard identifier.range(of: pattern, options: .regularExpression) != nil else {
            throw LongwayError("invalid \(role) name '\(identifier)'", at: location)
        }
    }

    private func inferSignatures(
        _ definitions: [FunctionDefinition]
    ) throws -> [String: FunctionSignature] {
        var previous: [String: FunctionSignature] = [:]

        for _ in 0...definitions.count {
            let inference = TypeInference()
            var drafts: [String: InferenceSignature] = [:]
            for definition in definitions {
                let previousSignature = previous[definition.name]
                drafts[definition.name] = InferenceSignature(
                    name: definition.name,
                    parameters: definition.parameters.enumerated().map { index, parameter in
                        let previousType = previousSignature?.parameters[index].type
                        return InferenceParameter(
                            name: parameter.name,
                            typeVariable: inference.makeVariable(
                                boundTo: previousType == .any ? nil : previousType
                            )
                        )
                    },
                    returnTypeVariable: inference.makeVariable(
                        boundTo: previousSignature?.returnType == .any
                            ? nil
                            : previousSignature?.returnType
                    )
                )
            }

            for definition in definitions {
                let draft = drafts[definition.name]!
                var variables: [String: Int] = [:]
                for parameter in draft.parameters {
                    variables[parameter.name] = parameter.typeVariable
                }
                let environment = InferenceEnvironment(variables: variables, functions: drafts)
                for form in definition.body.dropLast() {
                    try inferForm(form, environment: environment, inference: inference)
                }
                let result = try inferResultForm(
                    definition.body.last!,
                    environment: environment,
                    inference: inference
                )
                try inference.unify(
                    draft.returnTypeVariable,
                    result,
                    message: "function '\(definition.name)' has inconsistent return types",
                    at: definition.body.last!.location
                )
            }

            let resolved = drafts.mapValues { draft in
                FunctionSignature(
                    name: draft.name,
                    parameters: draft.parameters.map {
                        ParameterSignature(name: $0.name, type: inference.resolve($0.typeVariable))
                    },
                    returnType: inference.resolve(draft.returnTypeVariable)
                )
            }
            if signaturesMatch(previous, resolved) {
                return resolved
            }
            previous = resolved
        }
        return previous
    }

    private func signaturesMatch(
        _ left: [String: FunctionSignature],
        _ right: [String: FunctionSignature]
    ) -> Bool {
        guard left.count == right.count else { return false }
        for (name, leftSignature) in left {
            guard let rightSignature = right[name],
                  leftSignature.returnType == rightSignature.returnType,
                  leftSignature.parameters.map(\.type) == rightSignature.parameters.map(\.type)
            else { return false }
        }
        return true
    }

    private func inferForm(
        _ expression: Expression,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws {
        guard case let .list(parts) = expression.value, let head = parts.first,
              case let .symbol(formName) = head.value
        else {
            throw LongwayError("expected an action form", at: expression.location)
        }

        if formName == "let" {
            let prepared = try inferLetBindings(
                parts: parts,
                at: expression.location,
                environment: environment,
                inference: inference
            )
            for bodyForm in parts.dropFirst(2) {
                try inferForm(bodyForm, environment: prepared, inference: inference)
            }
            return
        }
        if formName == "if" {
            let arguments = Array(parts.dropFirst())
            try requireArgumentCount(3, action: "if", arguments: arguments, at: expression.location)
            let condition = try inferValue(arguments[0], environment: environment, inference: inference)
            try inference.constrain(
                condition,
                to: .boolean,
                message: "if expects a boolean condition",
                at: arguments[0].location
            )
            try inferForm(arguments[1], environment: environment, inference: inference)
            try inferForm(arguments[2], environment: environment, inference: inference)
            return
        }
        if environment.functions[formName] != nil {
            _ = try inferValue(expression, environment: environment, inference: inference)
            return
        }

        let arguments = Array(parts.dropFirst())
        switch formName {
        case "show-result":
            try requireArgumentCount(1, action: formName, arguments: arguments, at: expression.location)
            _ = try inferValue(arguments[0], environment: environment, inference: inference)
        case "notification", "open-url", "wait":
            break
        default:
            throw LongwayError("unknown action '\(formName)'", at: head.location)
        }
    }

    private func inferResultForm(
        _ expression: Expression,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> Int {
        if case let .list(parts) = expression.value, let head = parts.first,
           case let .symbol(formName) = head.value {
            if formName == "let" {
                let prepared = try inferLetBindings(
                    parts: parts,
                    at: expression.location,
                    environment: environment,
                    inference: inference
                )
                let body = Array(parts.dropFirst(2))
                for bodyForm in body.dropLast() {
                    try inferForm(bodyForm, environment: prepared, inference: inference)
                }
                return try inferResultForm(body.last!, environment: prepared, inference: inference)
            }
            if formName == "show-result" {
                let arguments = Array(parts.dropFirst())
                try requireArgumentCount(1, action: formName, arguments: arguments, at: expression.location)
                return try inferValue(arguments[0], environment: environment, inference: inference)
            }
        }
        return try inferValue(expression, environment: environment, inference: inference)
    }

    private func inferLetBindings(
        parts: [Expression],
        at location: SourceLocation,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> InferenceEnvironment {
        guard parts.count >= 3 else {
            throw LongwayError("let expects bindings and at least one body form", at: location)
        }
        guard case let .list(bindings) = parts[1].value else {
            throw LongwayError("let bindings must be a list", at: parts[1].location)
        }

        var localBindings: [String: Int] = [:]
        var names = Set<String>()
        for binding in bindings {
            guard case let .list(pair) = binding.value, pair.count == 2 else {
                throw LongwayError("let binding must contain a name and value", at: binding.location)
            }
            guard case let .symbol(name) = pair[0].value else {
                throw LongwayError("let binding name must be a symbol", at: pair[0].location)
            }
            guard names.insert(name).inserted else {
                throw LongwayError("duplicate let binding '\(name)'", at: pair[0].location)
            }
            localBindings[name] = try inferValue(pair[1], environment: environment, inference: inference)
        }

        var bodyEnvironment = environment
        bodyEnvironment.variables.merge(localBindings) { _, local in local }
        return bodyEnvironment
    }

    private func inferValue(
        _ expression: Expression,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> Int {
        switch expression.value {
        case .string:
            return inference.makeVariable(boundTo: .text)
        case .number:
            return inference.makeVariable(boundTo: .number)
        case .boolean:
            return inference.makeVariable(boundTo: .boolean)
        case let .symbol(name):
            guard let variable = environment.variables[name] else {
                throw LongwayError("unknown variable '\(name)'", at: expression.location)
            }
            return variable
        case let .list(parts):
            guard let head = parts.first, case let .symbol(operation) = head.value else {
                throw LongwayError("expected a value expression", at: expression.location)
            }
            let operands = Array(parts.dropFirst())
            if operation == "let" {
                let prepared = try inferLetBindings(
                    parts: parts,
                    at: expression.location,
                    environment: environment,
                    inference: inference
                )
                let body = Array(parts.dropFirst(2))
                for form in body.dropLast() {
                    try inferForm(form, environment: prepared, inference: inference)
                }
                return try inferResultForm(body.last!, environment: prepared, inference: inference)
            }
            if operation == "if" {
                try requireArgumentCount(3, action: operation, arguments: operands, at: expression.location)
                let condition = try inferValue(operands[0], environment: environment, inference: inference)
                try inference.constrain(
                    condition,
                    to: .boolean,
                    message: "if expects a boolean condition",
                    at: operands[0].location
                )
                let trueType = try inferValue(operands[1], environment: environment, inference: inference)
                let falseType = try inferValue(operands[2], environment: environment, inference: inference)
                try inference.unify(
                    trueType,
                    falseType,
                    message: "if branches must have matching types",
                    at: operands[2].location
                )
                return trueType
            }
            if mathOperation(operation) != nil {
                guard operands.count >= 2 else {
                    throw LongwayError("\(operation) expects at least 2 operands, got \(operands.count)", at: expression.location)
                }
                for operand in operands {
                    let type = try inferValue(operand, environment: environment, inference: inference)
                    try inference.constrain(
                        type,
                        to: .number,
                        message: "\(operation) expects number operands",
                        at: operand.location
                    )
                }
                return inference.makeVariable(boundTo: .number)
            }
            if comparisonOperators.contains(operation) {
                guard operands.count >= 2 else {
                    throw LongwayError("\(operation) expects at least 2 operands, got \(operands.count)", at: expression.location)
                }
                for operand in operands {
                    let type = try inferValue(operand, environment: environment, inference: inference)
                    try inference.constrain(
                        type,
                        to: .number,
                        message: "\(operation) expects number operands",
                        at: operand.location
                    )
                }
                return inference.makeVariable(boundTo: .boolean)
            }
            if operation == "not" {
                guard operands.count == 1 else {
                    throw LongwayError("not expects 1 operand, got \(operands.count)", at: expression.location)
                }
                let type = try inferValue(operands[0], environment: environment, inference: inference)
                try inference.constrain(
                    type,
                    to: .boolean,
                    message: "not expects boolean operands",
                    at: operands[0].location
                )
                return inference.makeVariable(boundTo: .boolean)
            }
            if operation == "and" || operation == "or" {
                guard operands.count >= 2 else {
                    throw LongwayError("\(operation) expects at least 2 operands, got \(operands.count)", at: expression.location)
                }
                for operand in operands {
                    let type = try inferValue(operand, environment: environment, inference: inference)
                    try inference.constrain(
                        type,
                        to: .boolean,
                        message: "\(operation) expects boolean operands",
                        at: operand.location
                    )
                }
                return inference.makeVariable(boundTo: .boolean)
            }
            if let function = environment.functions[operation] {
                guard operands.count == function.parameters.count else {
                    throw LongwayError(
                        functionArgumentCountMessage(
                            operation,
                            expected: function.parameters.count,
                            actual: operands.count
                        ),
                        at: expression.location
                    )
                }
                for (index, pair) in zip(operands, function.parameters).enumerated() {
                    let argumentType = try inferValue(pair.0, environment: environment, inference: inference)
                    if let parameterType = inference.boundType(pair.1.typeVariable) {
                        try inference.constrain(
                            argumentType,
                            to: parameterType,
                            message: "\(operation) argument \(index + 1) has incompatible type",
                            at: pair.0.location
                        )
                    }
                }
                return inference.makeVariable(
                    boundTo: inference.boundType(function.returnTypeVariable)
                )
            }
            throw LongwayError("unknown value form '\(operation)'", at: head.location)
        }
    }

    private func compileDefinition(
        _ definition: FunctionDefinition,
        signatures: [String: FunctionSignature]
    ) throws -> Workflow {
        let signature = signatures[definition.name]!
        var actions: [[String: Any]] = []
        var variables: [String: ActionOutputReference] = [:]

        for parameter in signature.parameters {
            let uuid = UUID().uuidString
            actions.append(action("is.workflow.actions.getvalueforkey", parameters: [
                "CustomOutputName": parameter.name,
                "WFDictionaryKey": parameter.name,
                "WFGetDictionaryValueType": "Value",
                "WFInput": shortcutInputAttachment()
            ], uuid: uuid))
            variables[parameter.name] = ActionOutputReference(
                type: parameter.type,
                name: parameter.name,
                uuid: uuid,
                isRuntimeTyped: false
            )
        }

        let environment = CompileEnvironment(variables: variables, functions: signatures)
        for form in definition.body.dropLast() {
            actions.append(contentsOf: try compileForm(form, environment: environment))
        }
        let result = try compileResultForm(definition.body.last!, environment: environment)
        actions.append(contentsOf: result.actions)
        let output = outputParameter(result.value, actions: &actions)
        actions.append(action("is.workflow.actions.output", parameters: [
            "WFOutput": output
        ]))

        return Workflow(
            name: definition.name,
            actions: actions,
            acceptsInput: !definition.parameters.isEmpty,
            outputType: signature.returnType
        )
    }

    private func compileForm(
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
        if environment.functions[formName] != nil {
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

    private func compileResultForm(
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

    private func compileLet(
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

    private func compileLetResult(
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

    private func compileLetBindings(
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

    private func compileAction(
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

    private func showResultAction(_ value: CompiledValue.Value) -> [[String: Any]] {
        let text: [String: Any]
        switch value {
        case let .literalString(string):
            text = textTokenString(string)
        case let .literalNumber(number):
            text = textTokenString(formatNumber(number))
        case let .literalBoolean(boolean):
            text = textTokenString(boolean ? "#t" : "#f")
        case let .output(output):
            text = actionOutputTokenString(output)
        }
        return [action("is.workflow.actions.showresult", parameters: ["Text": text], uuid: nil)]
    }

    private func compileValue(
        _ expression: Expression,
        environment: CompileEnvironment
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
            guard let output = environment.variables[name] else {
                throw LongwayError("unknown variable '\(name)'", at: expression.location)
            }
            return CompiledValue(actions: [], value: .output(output))

        case let .list(parts):
            guard let head = parts.first, case let .symbol(operation) = head.value else {
                throw LongwayError("expected a value expression", at: expression.location)
            }
            let operands = Array(parts.dropFirst())
            if operation == "let" {
                return try compileLetResult(
                    parts: parts,
                    at: expression.location,
                    environment: environment
                )
            }
            if operation == "if" {
                return try compileIfValue(
                    operands,
                    at: expression.location,
                    environment: environment
                )
            }
            if let shortcutOperation = mathOperation(operation) {
                return try compileMath(
                    operation,
                    shortcutOperation: shortcutOperation,
                    operands: operands,
                    at: expression.location,
                    environment: environment
                )
            }
            if comparisonOperators.contains(operation) {
                return try compileComparison(
                    operation,
                    operands: operands,
                    at: expression.location,
                    environment: environment
                )
            }
            if operation == "and" || operation == "or" || operation == "not" {
                return try compileLogical(
                    operation,
                    operands: operands,
                    at: expression.location,
                    environment: environment
                )
            }
            if let signature = environment.functions[operation] {
                return try compileFunctionCall(
                    signature,
                    arguments: operands,
                    at: expression.location,
                    environment: environment
                )
            }
            throw LongwayError("unknown value form '\(operation)'", at: head.location)

        case let .boolean(value):
            return CompiledValue(actions: [], value: .literalBoolean(value))
        }
    }

    private func compileFunctionCall(
        _ signature: FunctionSignature,
        arguments: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        guard arguments.count == signature.parameters.count else {
            throw LongwayError(
                functionArgumentCountMessage(
                    signature.name,
                    expected: signature.parameters.count,
                    actual: arguments.count
                ),
                at: location
            )
        }

        var actions: [[String: Any]] = []
        var items: [[String: Any]] = []
        for (index, pair) in zip(arguments, signature.parameters).enumerated() {
            let (argument, parameter) = pair
            let compiledArgument = try compileValue(argument, environment: environment)
            guard typesAreCompatible(compiledArgument.value.type, parameter.type) else {
                throw LongwayError(
                    "\(signature.name) argument \(index + 1) expects \(parameter.type.name), got \(compiledArgument.value.type.name)",
                    at: argument.location
                )
            }
            actions.append(contentsOf: compiledArgument.actions)
            items.append(dictionaryItem(
                key: parameter.name,
                value: compiledArgument.value,
                expectedType: parameter.type
            ))
        }

        let dictionaryUUID = UUID().uuidString
        let dictionaryOutputName = "Arguments"
        actions.append(action("is.workflow.actions.dictionary", parameters: [
            "CustomOutputName": dictionaryOutputName,
            "WFItems": [
                "Value": ["WFDictionaryFieldValueItems": items],
                "WFSerializationType": "WFDictionaryFieldValue"
            ]
        ], uuid: dictionaryUUID))

        let resultUUID = UUID().uuidString
        let resultName = "\(signature.name) Result"
        actions.append(action("is.workflow.actions.runworkflow", parameters: [
            "CustomOutputName": resultName,
            "WFInput": actionOutputAttachment(ActionOutputReference(
                type: .any,
                name: dictionaryOutputName,
                uuid: dictionaryUUID
            )),
            "WFWorkflowName": signature.name
        ], uuid: resultUUID))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(
                type: signature.returnType,
                name: resultName,
                uuid: resultUUID,
                isRuntimeTyped: false
            ))
        )
    }

    private func compileIfForm(
        arguments: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> [[String: Any]] {
        try requireArgumentCount(3, action: "if", arguments: arguments, at: location)
        let condition = try compileValue(arguments[0], environment: environment)
        try requireIfCondition(condition, at: arguments[0].location)
        let trueActions = try compileForm(arguments[1], environment: environment)
        let falseActions = try compileForm(arguments[2], environment: environment)
        return lowerActionConditional(
            condition: condition,
            trueActions: trueActions,
            falseActions: falseActions
        )
    }

    private func compileIfValue(
        _ arguments: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(3, action: "if", arguments: arguments, at: location)
        let condition = try compileValue(arguments[0], environment: environment)
        try requireIfCondition(condition, at: arguments[0].location)
        let trueBranch = try compileValue(arguments[1], environment: environment)
        let falseBranch = try compileValue(arguments[2], environment: environment)
        guard mergeTypes(trueBranch.value.type, falseBranch.value.type) != nil else {
            throw LongwayError(
                "if branches must have matching types, got \(trueBranch.value.type.name) and \(falseBranch.value.type.name)",
                at: arguments[2].location
            )
        }
        return lowerConditional(
            condition: condition,
            trueBranch: trueBranch,
            falseBranch: falseBranch
        )
    }

    private func compileMath(
        _ operation: String,
        shortcutOperation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        guard operands.count >= 2 else {
            throw LongwayError("\(operation) expects at least 2 operands, got \(operands.count)", at: location)
        }

        let first = try compileValue(operands[0], environment: environment)
        guard typesAreCompatible(first.value.type, .number) else {
            throw LongwayError("\(operation) expects number operands", at: operands[0].location)
        }

        var actions = first.actions
        var result = materializeNumber(first.value, into: &actions)

        for operand in operands.dropFirst() {
            let compiledOperand = try compileValue(operand, environment: environment)
            guard typesAreCompatible(compiledOperand.value.type, .number) else {
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

    private func compileComparison(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        guard operands.count >= 2 else {
            throw LongwayError("\(operation) expects at least 2 operands, got \(operands.count)", at: location)
        }

        let first = try compileValue(operands[0], environment: environment)
        guard typesAreCompatible(first.value.type, .number) else {
            throw LongwayError("\(operation) expects number operands", at: operands[0].location)
        }

        var actions = first.actions
        var left = materializeNumber(first.value, into: &actions)
        var comparisons: [NumericComparison] = []

        for (index, operand) in operands.dropFirst().enumerated() {
            let compiledOperand = try compileValue(operand, environment: environment)
            guard typesAreCompatible(compiledOperand.value.type, .number) else {
                throw LongwayError("\(operation) expects number operands", at: operand.location)
            }
            actions.append(contentsOf: compiledOperand.actions)
            var right = compiledOperand.value
            switch right {
            case .literalNumber(let number) where number == 0 && operation != "=":
                right = .output(materializeNumber(right, into: &actions))
            case let .output(output) where !output.isRuntimeTyped:
                right = .output(materializeNumber(right, into: &actions))
            default:
                break
            }
            comparisons.append(NumericComparison(left: left, right: right))

            if index < operands.count - 2 {
                left = materializeNumber(right, into: &actions)
            }
        }

        let comparison = lowerComparisonChain(
            operation,
            comparisons: comparisons[...]
        )
        return CompiledValue(
            actions: actions + comparison.actions,
            value: comparison.value
        )
    }

    private func lowerComparisonChain(
        _ operation: String,
        comparisons: ArraySlice<NumericComparison>
    ) -> CompiledValue {
        let comparison = comparisons.first!
        let falseResult = CompiledValue(actions: [], value: .literalBoolean(false))
        let trueResult: CompiledValue
        if comparisons.count == 1 {
            trueResult = CompiledValue(actions: [], value: .literalBoolean(true))
        } else {
            trueResult = lowerComparisonChain(
                operation,
                comparisons: comparisons.dropFirst()
            )
        }
        return lowerComparison(
            operation,
            comparison: comparison,
            trueBranch: trueResult,
            falseBranch: falseResult
        )
    }

    private func lowerComparison(
        _ operation: String,
        comparison: NumericComparison,
        trueBranch: CompiledValue,
        falseBranch: CompiledValue
    ) -> CompiledValue {
        let condition: Int
        switch operation {
        case "<": condition = 0
        case "<=": condition = 1
        case ">": condition = 2
        case ">=": condition = 3
        case "=": condition = 4
        default: preconditionFailure("unknown comparison operation")
        }
        return lowerNumericConditional(
            condition: condition,
            comparison: comparison,
            trueBranch: trueBranch,
            falseBranch: falseBranch
        )
    }

    private func lowerNumericConditional(
        condition: Int,
        comparison: NumericComparison,
        trueBranch: CompiledValue,
        falseBranch: CompiledValue
    ) -> CompiledValue {
        var conditionParameters: [String: Any] = ["WFCondition": condition]
        switch comparison.right {
        case let .literalNumber(number):
            conditionParameters["WFNumberValue"] = number
        case let .output(output):
            conditionParameters["WFConditionalActionString"] = actionOutputTokenString(output)
        case .literalString, .literalBoolean:
            preconditionFailure("non-number value cannot be used in a numeric comparison")
        }
        return lowerShortcutConditional(
            prefixActions: [],
            input: comparison.left,
            conditionParameters: conditionParameters,
            trueBranch: trueBranch,
            falseBranch: falseBranch
        )
    }

    private func compileLogical(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        if operation == "not" {
            guard operands.count == 1 else {
                throw LongwayError("not expects 1 operand, got \(operands.count)", at: location)
            }
            let operand = try compileValue(operands[0], environment: environment)
            try requireBoolean(operand, operation: operation, at: operands[0].location)
            return lowerConditional(
                condition: operand,
                trueBranch: CompiledValue(actions: [], value: .literalBoolean(false)),
                falseBranch: CompiledValue(actions: [], value: .literalBoolean(true))
            )
        }

        guard operands.count >= 2 else {
            throw LongwayError("\(operation) expects at least 2 operands, got \(operands.count)", at: location)
        }
        return try compileShortCircuitLogical(
            operation,
            operands: operands,
            environment: environment
        )
    }

    private func compileShortCircuitLogical(
        _ operation: String,
        operands: [Expression],
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        let first = try compileValue(operands[0], environment: environment)
        try requireBoolean(first, operation: operation, at: operands[0].location)

        let remaining: CompiledValue
        if operands.count == 2 {
            remaining = try compileValue(operands[1], environment: environment)
            try requireBoolean(remaining, operation: operation, at: operands[1].location)
        } else {
            remaining = try compileShortCircuitLogical(
                operation,
                operands: Array(operands.dropFirst()),
                environment: environment
            )
        }

        if operation == "and" {
            return lowerConditional(
                condition: first,
                trueBranch: remaining,
                falseBranch: CompiledValue(actions: [], value: .literalBoolean(false))
            )
        }
        return lowerConditional(
            condition: first,
            trueBranch: CompiledValue(actions: [], value: .literalBoolean(true)),
            falseBranch: remaining
        )
    }

    private func lowerConditional(
        condition: CompiledValue,
        trueBranch: CompiledValue,
        falseBranch: CompiledValue
    ) -> CompiledValue {
        var actions = condition.actions
        let conditionOutput = materializeBoolean(condition.value, into: &actions)
        return lowerShortcutConditional(
            prefixActions: actions,
            input: conditionOutput,
            conditionParameters: [
                "WFCondition": 4,
                "WFConditionalActionString": "#t"
            ],
            trueBranch: trueBranch,
            falseBranch: falseBranch
        )
    }

    private func lowerShortcutConditional(
        prefixActions: [[String: Any]],
        input: ActionOutputReference,
        conditionParameters: [String: Any],
        trueBranch: CompiledValue,
        falseBranch: CompiledValue
    ) -> CompiledValue {
        let resultType = mergeTypes(trueBranch.value.type, falseBranch.value.type)!
        var trueActions = trueBranch.actions
        _ = emitValue(trueBranch.value, into: &trueActions)
        var falseActions = falseBranch.actions
        _ = emitValue(falseBranch.value, into: &falseActions)

        let conditional = lowerShortcutConditionalActions(
            prefixActions: prefixActions,
            input: input,
            conditionParameters: conditionParameters,
            trueActions: trueActions,
            falseActions: falseActions
        )
        return CompiledValue(
            actions: conditional.actions,
            value: .output(ActionOutputReference(
                type: resultType,
                name: "If Result",
                uuid: conditional.resultUUID
            ))
        )
    }

    private func lowerActionConditional(
        condition: CompiledValue,
        trueActions: [[String: Any]],
        falseActions: [[String: Any]]
    ) -> [[String: Any]] {
        var actions = condition.actions
        let conditionOutput = materializeBoolean(condition.value, into: &actions)
        return lowerShortcutConditionalActions(
            prefixActions: actions,
            input: conditionOutput,
            conditionParameters: [
                "WFCondition": 4,
                "WFConditionalActionString": "#t"
            ],
            trueActions: trueActions,
            falseActions: falseActions
        ).actions
    }

    private func lowerShortcutConditionalActions(
        prefixActions: [[String: Any]],
        input: ActionOutputReference,
        conditionParameters: [String: Any],
        trueActions: [[String: Any]],
        falseActions: [[String: Any]]
    ) -> (actions: [[String: Any]], resultUUID: String) {
        var actions = prefixActions
        let groupingIdentifier = UUID().uuidString
        var startParameters = conditionParameters
        startParameters["GroupingIdentifier"] = groupingIdentifier
        startParameters["WFControlFlowMode"] = 0
        startParameters["WFInput"] = conditionalInput(input)
        actions.append(action(
            "is.workflow.actions.conditional",
            parameters: startParameters
        ))
        actions.append(contentsOf: trueActions)
        actions.append(action("is.workflow.actions.conditional", parameters: [
            "GroupingIdentifier": groupingIdentifier,
            "WFControlFlowMode": 1
        ]))
        actions.append(contentsOf: falseActions)

        let resultUUID = UUID().uuidString
        actions.append(action("is.workflow.actions.conditional", parameters: [
            "GroupingIdentifier": groupingIdentifier,
            "WFControlFlowMode": 2
        ], uuid: resultUUID))
        return (actions, resultUUID)
    }

    private func requireIfCondition(
        _ condition: CompiledValue,
        at location: SourceLocation
    ) throws {
        guard typesAreCompatible(condition.value.type, .boolean) else {
            throw LongwayError("if expects a boolean condition", at: location)
        }
    }

    private func requireBoolean(
        _ value: CompiledValue,
        operation: String,
        at location: SourceLocation
    ) throws {
        guard typesAreCompatible(value.value.type, .boolean) else {
            throw LongwayError("\(operation) expects boolean operands", at: location)
        }
    }

    private func materialize(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalString(text):
            return emitText(textTokenString(text), type: .text, into: &actions)

        case .literalNumber:
            return materializeNumber(value, into: &actions)

        case .literalBoolean:
            return materializeBoolean(value, into: &actions)

        case let .output(output):
            return output
        }
    }

    private func materializeBoolean(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalBoolean(boolean):
            return emitText(textTokenString(boolean ? "#t" : "#f"), type: .boolean, into: &actions)
        case let .output(output):
            precondition(typesAreCompatible(output.type, .boolean))
            if output.isRuntimeTyped {
                return ActionOutputReference(type: .boolean, name: output.name, uuid: output.uuid)
            }
            return emitText(actionOutputTokenString(output), type: .boolean, into: &actions)
        case .literalString, .literalNumber:
            preconditionFailure("non-boolean value cannot be materialized as a boolean")
        }
    }

    private func emitValue(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalString(text):
            return emitText(textTokenString(text), type: .text, into: &actions)
        case .literalNumber:
            return emitNumber(value, into: &actions)
        case .literalBoolean:
            return emitBoolean(value, into: &actions)
        case let .output(output):
            switch output.type {
            case .text:
                return emitText(actionOutputTokenString(output), type: .text, into: &actions)
            case .number:
                return emitNumber(value, into: &actions)
            case .boolean:
                return emitBoolean(value, into: &actions)
            case .any:
                return emitGeneric(output, into: &actions)
            }
        }
    }

    private func emitBoolean(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        switch value {
        case let .literalBoolean(boolean):
            return emitText(textTokenString(boolean ? "#t" : "#f"), type: .boolean, into: &actions)
        case let .output(output):
            precondition(typesAreCompatible(output.type, .boolean))
            return emitText(actionOutputTokenString(output), type: .boolean, into: &actions)
        case .literalString, .literalNumber:
            preconditionFailure("non-boolean value cannot be emitted as a boolean")
        }
    }

    private func emitGeneric(
        _ output: ActionOutputReference,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        let uuid = UUID().uuidString
        let name = "Value"
        actions.append(action("is.workflow.actions.getvariable", parameters: [
            "CustomOutputName": name,
            "WFVariable": actionOutputAttachment(output)
        ], uuid: uuid))
        return ActionOutputReference(type: .any, name: name, uuid: uuid)
    }

    private func emitText(
        _ text: [String: Any],
        type: ValueType,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        let uuid = UUID().uuidString
        actions.append(action("is.workflow.actions.gettext", parameters: [
            "WFTextActionText": text
        ], uuid: uuid))
        return ActionOutputReference(type: type, name: "Text", uuid: uuid)
    }

    private func emitNumber(
        _ value: CompiledValue.Value,
        into actions: inout [[String: Any]]
    ) -> ActionOutputReference {
        let uuid = UUID().uuidString
        actions.append(action("is.workflow.actions.number", parameters: [
            "WFNumberActionNumber": numberParameter(value)
        ], uuid: uuid))
        return ActionOutputReference(type: .number, name: "Number", uuid: uuid)
    }

    private func materializeNumber(
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

    private func numberParameter(_ value: CompiledValue.Value) -> Any {
        switch value {
        case let .literalNumber(number):
            return number
        case let .output(output):
            return actionOutputAttachment(output)
        case .literalString, .literalBoolean:
            preconditionFailure("non-number value cannot be used as a number parameter")
        }
    }

    private func outputParameter(
        _ value: CompiledValue.Value,
        actions: inout [[String: Any]]
    ) -> [String: Any] {
        switch value {
        case let .literalString(string):
            return textTokenString(string)
        case let .literalBoolean(boolean):
            return textTokenString(boolean ? "#t" : "#f")
        case .literalNumber:
            return actionOutputTokenString(emitNumber(value, into: &actions))
        case let .output(output):
            return actionOutputTokenString(output)
        }
    }

    private func dictionaryItem(
        key: String,
        value: CompiledValue.Value,
        expectedType: ValueType
    ) -> [String: Any] {
        let valueType = expectedType == .any ? value.type : expectedType
        let itemType = valueType == .number ? 3 : 0
        let dictionaryValue: [String: Any]
        switch value {
        case let .literalString(string):
            dictionaryValue = textTokenString(string)
        case let .literalNumber(number):
            dictionaryValue = textTokenString(formatNumber(number))
        case let .literalBoolean(boolean):
            dictionaryValue = textTokenString(boolean ? "#t" : "#f")
        case let .output(output):
            dictionaryValue = actionOutputTokenString(output)
        }
        return [
            "WFItemType": itemType,
            "WFKey": textTokenString(key),
            "WFValue": dictionaryValue
        ]
    }

    private func typesAreCompatible(_ left: ValueType, _ right: ValueType) -> Bool {
        left == .any || right == .any || left == right
    }

    private func mergeTypes(_ left: ValueType, _ right: ValueType) -> ValueType? {
        if left == .any { return right }
        if right == .any { return left }
        return left == right ? left : nil
    }

    private var comparisonOperators: Set<String> {
        ["=", "<", "<=", ">", ">="]
    }

    private var reservedFunctionNames: Set<String> {
        [
            "define", "let", "if", "+", "-", "*", "/", "=", "<", "<=", ">", ">=",
            "and", "or", "not", "show-result", "notification", "open-url", "wait"
        ]
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

    private func functionArgumentCountMessage(
        _ function: String,
        expected: Int,
        actual: Int
    ) -> String {
        let noun = expected == 1 ? "argument" : "arguments"
        return "\(function) expects \(expected) \(noun), got \(actual)"
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

    private func shortcutInputAttachment() -> [String: Any] {
        [
            "Value": ["Type": "ExtensionInput"],
            "WFSerializationType": "WFTextTokenAttachment"
        ]
    }

    private func conditionalInput(_ output: ActionOutputReference) -> [String: Any] {
        [
            "Type": "Variable",
            "Variable": actionOutputAttachment(output)
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

private enum ValueType: Equatable {
    case text
    case number
    case boolean
    case any

    var name: String {
        switch self {
        case .text: "text"
        case .number: "number"
        case .boolean: "boolean"
        case .any: "value"
        }
    }
}

private struct ActionOutputReference {
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

private struct FunctionParameter {
    let name: String
    let location: SourceLocation
}

private struct FunctionDefinition {
    let name: String
    let nameLocation: SourceLocation
    let parameters: [FunctionParameter]
    let body: [Expression]
    let location: SourceLocation
}

private struct ParameterSignature {
    let name: String
    let type: ValueType
}

private struct FunctionSignature {
    let name: String
    let parameters: [ParameterSignature]
    let returnType: ValueType
}

private struct CompileEnvironment {
    var variables: [String: ActionOutputReference]
    let functions: [String: FunctionSignature]
}

private struct InferenceParameter {
    let name: String
    let typeVariable: Int
}

private struct InferenceSignature {
    let name: String
    let parameters: [InferenceParameter]
    let returnTypeVariable: Int
}

private struct InferenceEnvironment {
    var variables: [String: Int]
    let functions: [String: InferenceSignature]
}

private final class TypeInference {
    private var parents: [Int] = []
    private var ranks: [Int] = []
    private var bindings: [ValueType?] = []

    func makeVariable(boundTo type: ValueType? = nil) -> Int {
        let index = parents.count
        parents.append(index)
        ranks.append(0)
        bindings.append(type)
        return index
    }

    func constrain(
        _ variable: Int,
        to type: ValueType,
        message: String,
        at location: SourceLocation
    ) throws {
        let root = find(variable)
        if let existing = bindings[root], existing != type {
            throw LongwayError(message, at: location)
        }
        bindings[root] = type
    }

    func unify(
        _ left: Int,
        _ right: Int,
        message: String,
        at location: SourceLocation
    ) throws {
        var leftRoot = find(left)
        var rightRoot = find(right)
        guard leftRoot != rightRoot else { return }

        if let leftType = bindings[leftRoot], let rightType = bindings[rightRoot], leftType != rightType {
            throw LongwayError(message, at: location)
        }
        if ranks[leftRoot] < ranks[rightRoot] {
            swap(&leftRoot, &rightRoot)
        }
        parents[rightRoot] = leftRoot
        if ranks[leftRoot] == ranks[rightRoot] {
            ranks[leftRoot] += 1
        }
        if bindings[leftRoot] == nil {
            bindings[leftRoot] = bindings[rightRoot]
        }
    }

    func resolve(_ variable: Int) -> ValueType {
        bindings[find(variable)] ?? .any
    }

    func boundType(_ variable: Int) -> ValueType? {
        bindings[find(variable)]
    }

    private func find(_ variable: Int) -> Int {
        if parents[variable] != variable {
            parents[variable] = find(parents[variable])
        }
        return parents[variable]
    }
}

private struct NumericComparison {
    let left: ActionOutputReference
    let right: CompiledValue.Value
}

private struct CompiledValue {
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

private struct Workflow {
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
        case .any:
            ["WFStringContentItem", "WFNumberContentItem", "WFGenericFileContentItem"]
        }
    }
}

private extension Expression {
    var symbol: String? {
        guard case let .symbol(value) = self.value else { return nil }
        return value
    }
}
