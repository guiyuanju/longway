import Foundation

/// Lowers `if`, comparisons, and short-circuit logic to Shortcuts' `conditional`
/// action. All of them ultimately funnel through `lowerShortcutConditionalActions`,
/// which emits the three-part GroupingIdentifier-linked block Shortcuts expects.
extension FunctionCompiler {
    func compileIfForm(
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

    func compileIfValue(
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

    func lowerComparisonChain(
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

    func lowerComparison(
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

    func lowerNumericConditional(
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
            conditionParameters["WFConditionalActionString"] = ShortcutPlist.actionOutputTokenString(
                name: output.name,
                uuid: output.uuid
            )
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

    func lowerConditional(
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

    func lowerShortcutConditional(
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

    func lowerActionConditional(
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

    func lowerShortcutConditionalActions(
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
        startParameters["WFInput"] = ShortcutPlist.conditionalInput(name: input.name, uuid: input.uuid)
        actions.append(ShortcutPlist.action(
            "is.workflow.actions.conditional",
            parameters: startParameters
        ))
        actions.append(contentsOf: trueActions)
        actions.append(ShortcutPlist.action("is.workflow.actions.conditional", parameters: [
            "GroupingIdentifier": groupingIdentifier,
            "WFControlFlowMode": 1
        ]))
        actions.append(contentsOf: falseActions)

        let resultUUID = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.conditional", parameters: [
            "GroupingIdentifier": groupingIdentifier,
            "WFControlFlowMode": 2
        ], uuid: resultUUID))
        return (actions, resultUUID)
    }

    func requireIfCondition(
        _ condition: CompiledValue,
        at location: SourceLocation
    ) throws {
        guard typesAreCompatible(condition.value.type, .boolean) else {
            throw LongwayError("if expects a boolean condition", at: location)
        }
    }

    func requireBoolean(
        _ value: CompiledValue,
        operation: String,
        at location: SourceLocation
    ) throws {
        guard typesAreCompatible(value.value.type, .boolean) else {
            throw LongwayError("\(operation) expects boolean operands", at: location)
        }
    }
}
