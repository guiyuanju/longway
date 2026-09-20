import Foundation

/// Text processing and interactive value-producing actions used by ordinary
/// Longway expressions. Prompts, custom separators, and date formats are kept
/// literal for now because those are the parameter shapes confirmed from
/// Shortcuts-authored clipboard actions.
extension FunctionCompiler {
    func compileTextOperation(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        switch operation {
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
        default:
            preconditionFailure("unknown text operation")
        }
    }

    func compileInteractiveOperation(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        switch operation {
        case "choose-from-list":
            return try compileChooseFromList(operands, at: location, environment: environment)
        case "ask-text", "ask-number":
            return try compileAsk(operation, operands: operands, at: location)
        case "format-current-date":
            return try compileCurrentDate(operands, at: location)
        default:
            preconditionFailure("unknown interactive operation")
        }
    }

    private func compileStringAppend(
        _ operands: [Expression],
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        var actions: [[String: Any]] = []
        var segments: [ShortcutPlist.TextSegment] = []
        var allLiteral = true
        var literal = ""

        for operand in operands {
            let compiled = try compileValue(operand, environment: environment)
            guard typesAreCompatible(compiled.value.type, .text) else {
                throw LongwayError("string-append expects text operands", at: operand.location)
            }
            actions.append(contentsOf: compiled.actions)
            switch compiled.value {
            case let .literalString(string):
                literal += string
                segments.append(.literal(string))
            case let .output(output):
                allLiteral = false
                segments.append(.actionOutput(name: output.name, uuid: output.uuid))
            case .literalNumber, .literalBoolean:
                preconditionFailure("type check admitted a non-text literal")
            }
        }

        if allLiteral {
            return CompiledValue(actions: actions, value: .literalString(literal))
        }
        let output = emitText(
            ShortcutPlist.textTokenString(segments: segments),
            type: .text,
            into: &actions
        )
        return CompiledValue(actions: actions, value: .output(output))
    }

    private func compileNumberToText(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: "number->text", arguments: operands, at: location)
        let compiled = try compileValue(operands[0], environment: environment)
        guard typesAreCompatible(compiled.value.type, .number) else {
            throw LongwayError("number->text expects a number", at: operands[0].location)
        }
        if case let .literalNumber(number) = compiled.value {
            return CompiledValue(
                actions: compiled.actions,
                value: .literalString(ShortcutPlist.formatNumber(number))
            )
        }
        guard case let .output(output) = compiled.value else {
            preconditionFailure("a computed number must be an action output")
        }
        var actions = compiled.actions
        let text = emitText(
            ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid),
            type: .text,
            into: &actions
        )
        return CompiledValue(actions: actions, value: .output(text))
    }

    private func compileSplitText(
        _ operation: String,
        mode: String?,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: operation, arguments: operands, at: location)
        let input = try compileTextReference(operation, operands[0], environment: environment)
        var parameters: [String: Any] = [
            "CustomOutputName": "Split Text",
            "text": ShortcutPlist.actionOutputAttachment(name: input.reference.name, uuid: input.reference.uuid)
        ]
        if let mode {
            parameters["WFTextSeparator"] = mode
        }
        return splitTextResult(parameters: parameters, actions: input.actions)
    }

    private func compileCustomSplit(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(2, action: "split-text", arguments: operands, at: location)
        guard case let .string(separator) = operands[1].value else {
            throw LongwayError("split-text separator must be a string literal", at: operands[1].location)
        }
        let input = try compileTextReference("split-text", operands[0], environment: environment)
        return splitTextResult(parameters: [
            "CustomOutputName": "Split Text",
            "WFTextCustomSeparator": separator,
            "WFTextSeparator": "Custom",
            "text": ShortcutPlist.actionOutputAttachment(name: input.reference.name, uuid: input.reference.uuid)
        ], actions: input.actions)
    }

    private func splitTextResult(
        parameters: [String: Any],
        actions precedingActions: [[String: Any]]
    ) -> CompiledValue {
        var actions = precedingActions
        let uuid = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.text.split", parameters: parameters, uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(type: .list, name: "Split Text", uuid: uuid))
        )
    }

    private func compileChooseFromList(
        _ operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(2, action: "choose-from-list", arguments: operands, at: location)
        let list = try compileValue(operands[0], environment: environment)
        guard typesAreCompatible(list.value.type, .list), case let .output(output) = list.value else {
            throw LongwayError("choose-from-list expects a list", at: operands[0].location)
        }
        let prompt = try literalString(
            operands[1],
            message: "choose-from-list prompt must be a string literal"
        )
        var actions = list.actions
        let uuid = UUID().uuidString
        let name = "Chosen Item"
        actions.append(ShortcutPlist.action("is.workflow.actions.choosefromlist", parameters: [
            "CustomOutputName": name,
            "WFChooseFromListActionPrompt": prompt,
            "WFInput": ShortcutPlist.actionOutputAttachment(name: output.name, uuid: output.uuid)
        ], uuid: uuid))
        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(
                type: .any,
                name: name,
                uuid: uuid,
                isRuntimeTyped: false
            ))
        )
    }

    private func compileAsk(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: operation, arguments: operands, at: location)
        let prompt = try literalString(
            operands[0],
            message: "\(operation) prompt must be a string literal"
        )
        let type: ValueType = operation == "ask-number" ? .number : .text
        let name = operation == "ask-number" ? "Provided Number" : "Provided Text"
        var parameters: [String: Any] = [
            "CustomOutputName": name,
            "WFAskActionPrompt": prompt
        ]
        if operation == "ask-number" {
            parameters["WFInputType"] = "Number"
        }
        let uuid = UUID().uuidString
        return CompiledValue(
            actions: [ShortcutPlist.action("is.workflow.actions.ask", parameters: parameters, uuid: uuid)],
            value: .output(ActionOutputReference(type: type, name: name, uuid: uuid))
        )
    }

    private func compileCurrentDate(
        _ operands: [Expression],
        at location: SourceLocation
    ) throws -> CompiledValue {
        try requireArgumentCount(1, action: "format-current-date", arguments: operands, at: location)
        let format = try literalString(
            operands[0],
            message: "format-current-date format must be a string literal"
        )
        let uuid = UUID().uuidString
        let name = "Formatted Date"
        return CompiledValue(
            actions: [ShortcutPlist.action("is.workflow.actions.format.date", parameters: [
                "CustomOutputName": name,
                "WFDate": ShortcutPlist.currentDateTokenString(),
                "WFDateFormat": format,
                "WFDateFormatStyle": "Custom"
            ], uuid: uuid)],
            value: .output(ActionOutputReference(type: .text, name: name, uuid: uuid))
        )
    }

    private func compileTextReference(
        _ operation: String,
        _ expression: Expression,
        environment: CompileEnvironment
    ) throws -> (actions: [[String: Any]], reference: ActionOutputReference) {
        let compiled = try compileValue(expression, environment: environment)
        guard typesAreCompatible(compiled.value.type, .text) else {
            throw LongwayError("\(operation) expects text", at: expression.location)
        }
        var actions = compiled.actions
        let reference = materialize(compiled.value, into: &actions)
        return (actions, reference)
    }

    private func literalString(
        _ expression: Expression,
        message: String
    ) throws -> String {
        guard case let .string(value) = expression.value else {
            throw LongwayError(message, at: expression.location)
        }
        return value
    }
}
