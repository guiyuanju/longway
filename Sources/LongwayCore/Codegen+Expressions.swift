import Foundation

struct NumericComparison {
    let left: ActionOutputReference
    let right: CompiledValue.Value
}

/// Value-producing forms: literals, variables, calls, arithmetic, comparisons,
/// and logical operators. Control-flow value forms (`let`, `if`) dispatch here
/// but are implemented in Codegen.swift / Codegen+Conditionals.swift.
extension FunctionCompiler {
    func compileValue(
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
            let location = expression.location

            switch operation {
            case "let", "let*":
                return try compileLetResult(parts: parts, at: location, environment: environment)
            case "if":
                return try compileIfValue(operands, at: location, environment: environment)
            case "+", "-", "*", "/":
                return try compileMath(operation, operands: operands, at: location, environment: environment)
            case "=", "<", "<=", ">", ">=":
                return try compileComparison(operation, operands: operands, at: location, environment: environment)
            case "and", "or", "not":
                return try compileLogical(operation, operands: operands, at: location, environment: environment)

            case "list":
                return try compileListLiteral(operands, environment: environment)
            case "length":
                return try compileLength(operands, at: location, environment: environment)
            case "empty?":
                return try compileEmpty(operands, at: location, environment: environment)
            case "first":
                return try compileItem(operation, specifier: "First Item", operands: operands, at: location, environment: environment)
            case "last":
                return try compileItem(operation, specifier: "Last Item", operands: operands, at: location, environment: environment)
            case "list-ref":
                return try compileListRef(operands, at: location, environment: environment)

            case "dict":
                return try compileDictionaryLiteral(operands, at: location, environment: environment)
            case "dict-ref":
                return try compileDictionaryRef(operands, at: location, environment: environment)
            case "dict-set":
                return try compileDictionarySet(operands, at: location, environment: environment)
            case "dict-keys":
                return try compileDictionaryContents(
                    operation, valueType: "All Keys", name: "Dictionary Keys",
                    operands: operands, at: location, environment: environment
                )
            case "dict-values":
                return try compileDictionaryContents(
                    operation, valueType: "All Values", name: "Dictionary Values",
                    operands: operands, at: location, environment: environment
                )

            case "string-append":
                return try compileStringAppend(operands, environment: environment)
            case "number->text":
                return try compileNumberToText(operands, at: location, environment: environment)
            case "split-lines":
                return try compileSplitText(operation, mode: nil, operands: operands, at: location, environment: environment)
            case "split-whitespace":
                return try compileSplitText(operation, mode: "Spaces", operands: operands, at: location, environment: environment)
            case "split-text":
                return try compileCustomSplit(operands, at: location, environment: environment)

            case "choose-from-list":
                return try compileChooseFromList(operands, at: location, environment: environment)
            case "ask-text", "ask-number":
                return try compileAsk(operation, operands: operands, at: location)
            case "format-current-date":
                return try compileCurrentDate(operands, at: location)

            default:
                break
            }

            if let externalAction = catalog.actions[operation] {
                guard externalAction.result != nil else {
                    throw LongwayError("external action '\(operation)' does not produce a value", at: location)
                }
                let compiled = try compileExternalAction(
                    externalAction,
                    operands: operands,
                    at: location,
                    environment: environment
                )
                return CompiledValue(actions: compiled.actions, value: compiled.value!)
            }
            if let signature = signatures[operation] {
                return try compileFunctionCall(
                    signature,
                    arguments: operands,
                    at: location,
                    environment: environment
                )
            }
            throw LongwayError("unknown value form '\(operation)'", at: head.location)

        case let .boolean(value):
            return CompiledValue(actions: [], value: .literalBoolean(value))
        }
    }

    func compileFunctionCall(
        _ signature: FunctionSignature,
        arguments: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        guard arguments.count == signature.parameters.count else {
            throw LongwayError(
                argumentCountMessage(
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
                key: .literalString(parameter.name),
                value: compiledArgument.value,
                expectedType: parameter.type
            ))
        }

        let dictionaryUUID = UUID().uuidString
        let dictionaryOutputName = "Arguments"
        actions.append(ShortcutPlist.action("is.workflow.actions.dictionary", parameters: [
            "CustomOutputName": dictionaryOutputName,
            "WFItems": ShortcutPlist.dictionaryFieldValue(items: items)
        ], uuid: dictionaryUUID))

        let resultUUID = UUID().uuidString
        let resultName = "\(signature.name) Result"
        actions.append(ShortcutPlist.action("is.workflow.actions.runworkflow", parameters: [
            "CustomOutputName": resultName,
            "WFInput": ShortcutPlist.actionOutputAttachment(name: dictionaryOutputName, uuid: dictionaryUUID),
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

    func compileMath(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        guard operands.count >= 2 else {
            throw LongwayError("\(operation) expects at least 2 arguments, got \(operands.count)", at: location)
        }

        let shortcutOperation = mathOperations[operation]!
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
            actions.append(ShortcutPlist.action("is.workflow.actions.math", parameters: [
                "WFInput": ShortcutPlist.actionOutputAttachment(name: result.name, uuid: result.uuid),
                "WFMathOperation": shortcutOperation,
                "WFMathOperand": numberParameter(compiledOperand.value)
            ], uuid: uuid))
            result = ActionOutputReference(type: .number, name: "Calculation Result", uuid: uuid)
        }

        return CompiledValue(actions: actions, value: .output(result))
    }

    func compileComparison(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        guard operands.count >= 2 else {
            throw LongwayError("\(operation) expects at least 2 arguments, got \(operands.count)", at: location)
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
            if case let .output(output) = right, !output.isRuntimeTyped {
                right = .output(materializeNumber(right, into: &actions))
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

    func compileLogical(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        if operation == "not" {
            try requireArgumentCount(1, action: operation, arguments: operands, at: location)
            let operand = try compileValue(operands[0], environment: environment)
            try requireBoolean(operand, operation: operation, at: operands[0].location)
            return lowerConditional(
                condition: operand,
                trueBranch: CompiledValue(actions: [], value: .literalBoolean(false)),
                falseBranch: CompiledValue(actions: [], value: .literalBoolean(true))
            )
        }

        guard operands.count >= 2 else {
            throw LongwayError("\(operation) expects at least 2 arguments, got \(operands.count)", at: location)
        }
        return try compileShortCircuitLogical(
            operation,
            operands: operands,
            environment: environment
        )
    }

    func compileShortCircuitLogical(
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
}
