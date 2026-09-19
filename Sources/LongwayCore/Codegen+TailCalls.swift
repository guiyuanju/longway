import Foundation

/// Shortcuts has no native way to exit a loop early or run a `while`-style loop:
/// the only bounded-count `Repeat` action always runs its full count, and the
/// accepted platform idiom for a dynamic loop is to guard the repeated actions
/// with an `If` and let the remaining iterations no-op once the condition no
/// longer holds. `tailCallLoopLimit` is that bound. It trades an unbounded
/// (but Shortcut-runtime-call-stack-limited) recursion depth for a much larger,
/// fixed number of cheap in-workflow iterations: recursion deeper than this
/// still "completes" but returns whatever the accumulator held at the bound,
/// rather than the fully reduced result. Raise it if real-world functions need
/// more headroom; there is currently no way to detect and report the overrun
/// at runtime without an unverified error-signaling action.
let tailCallLoopLimit = 2000

/// The named Shortcuts variable that carries a tail-recursive loop's return
/// value. `#` cannot appear in a source identifier (see DefinitionParser's
/// identifier pattern), so this can never collide with a real parameter name.
private let tailCallResultVariableName = "#result"

/// A function is loop-compiled only when its entire body is one expression
/// (no statements that would need to fire once per logical call, since a
/// no-progress loop iteration silently re-runs whatever's in tail position)
/// whose tail positions - through `let` and `if` - contain no action-catalog
/// side effects and reach a direct self-call with matching arity. Anything
/// else (mutual recursion, non-tail recursion, side effects) falls back to
/// the existing Run-Shortcut-per-call recursion, unchanged.
func isTailRecursive(_ definition: FunctionDefinition) -> Bool {
    guard definition.body.count == 1, let body = definition.body.first else { return false }
    guard !containsDisqualifyingAction(body) else { return false }
    return tailSelfCall(body, functionName: definition.name, arity: definition.parameters.count)
}

private func containsDisqualifyingAction(_ expression: Expression) -> Bool {
    guard case let .list(parts) = expression.value, let head = parts.first,
          case let .symbol(formName) = head.value
    else {
        return false
    }
    switch formName {
    case "show-result", "notification", "open-url", "wait":
        return true
    case "let":
        guard parts.count >= 3 else { return false }
        return parts.dropFirst(2).contains { containsDisqualifyingAction($0) }
    case "if":
        let arguments = Array(parts.dropFirst())
        guard arguments.count == 3 else { return false }
        return containsDisqualifyingAction(arguments[1]) || containsDisqualifyingAction(arguments[2])
    default:
        return false
    }
}

private func tailSelfCall(
    _ expression: Expression,
    functionName: String,
    arity: Int
) -> Bool {
    guard case let .list(parts) = expression.value, let head = parts.first,
          case let .symbol(formName) = head.value
    else {
        return false
    }
    switch formName {
    case "let":
        guard parts.count >= 3, let last = parts.dropFirst(2).last else { return false }
        return tailSelfCall(last, functionName: functionName, arity: arity)
    case "if":
        let arguments = Array(parts.dropFirst())
        guard arguments.count == 3 else { return false }
        return tailSelfCall(arguments[1], functionName: functionName, arity: arity)
            || tailSelfCall(arguments[2], functionName: functionName, arity: arity)
    case functionName:
        return parts.count - 1 == arity
    default:
        return false
    }
}

extension FunctionCompiler {
    /// Lowers a tail-recursive definition to: seed one named Shortcuts variable
    /// per parameter, `Repeat` a fixed number of times re-reading and (while a
    /// base case hasn't been reached) advancing them in place, then read back
    /// whichever value a base case last wrote into the result variable.
    func compileTailRecursiveLoop(
        _ definition: FunctionDefinition,
        signature: FunctionSignature,
        parameterOutputs: [String: ActionOutputReference]
    ) throws -> CompiledValue {
        var actions: [[String: Any]] = []

        for parameter in signature.parameters {
            let initial = parameterOutputs[parameter.name]!
            let seeded = emitValue(.output(initial), into: &actions)
            actions.append(ShortcutPlist.action("is.workflow.actions.setvariable", parameters: [
                "WFVariableName": parameter.name,
                "WFInput": ShortcutPlist.actionOutputAttachment(name: seeded.name, uuid: seeded.uuid)
            ]))
        }

        var iterationActions: [[String: Any]] = []
        var loopVariables: [String: ActionOutputReference] = [:]
        for parameter in signature.parameters {
            let uuid = UUID().uuidString
            iterationActions.append(ShortcutPlist.action("is.workflow.actions.getvariable", parameters: [
                "CustomOutputName": parameter.name,
                "WFVariable": ShortcutPlist.namedVariableAttachment(name: parameter.name)
            ], uuid: uuid))
            loopVariables[parameter.name] = ActionOutputReference(
                type: parameter.type,
                name: parameter.name,
                uuid: uuid,
                isRuntimeTyped: false
            )
        }

        iterationActions.append(contentsOf: try compileTailStep(
            definition.body[0],
            selfCallName: definition.name,
            parameterNames: definition.parameters.map(\.name),
            resultVariableName: tailCallResultVariableName,
            environment: CompileEnvironment(variables: loopVariables)
        ))

        let groupingIdentifier = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.repeat.count", parameters: [
            "GroupingIdentifier": groupingIdentifier,
            "WFControlFlowMode": 0,
            "WFRepeatCount": tailCallLoopLimit
        ]))
        actions.append(contentsOf: iterationActions)
        actions.append(ShortcutPlist.action("is.workflow.actions.repeat.count", parameters: [
            "GroupingIdentifier": groupingIdentifier,
            "WFControlFlowMode": 2
        ]))

        let resultUUID = UUID().uuidString
        actions.append(ShortcutPlist.action("is.workflow.actions.getvariable", parameters: [
            "CustomOutputName": "Result",
            "WFVariable": ShortcutPlist.namedVariableAttachment(name: tailCallResultVariableName)
        ], uuid: resultUUID))

        return CompiledValue(
            actions: actions,
            value: .output(ActionOutputReference(
                type: signature.returnType,
                name: "Result",
                uuid: resultUUID,
                isRuntimeTyped: false
            ))
        )
    }

    /// Walks the same `let`/`if` tail-position shape `tailSelfCall` validated,
    /// emitting statements instead of a value: a base-case leaf records its
    /// value into the result variable, a recursive-step leaf computes all of
    /// its new argument values before overwriting any parameter variable
    /// (matching call-by-value evaluation order).
    func compileTailStep(
        _ expression: Expression,
        selfCallName: String,
        parameterNames: [String],
        resultVariableName: String,
        environment: CompileEnvironment
    ) throws -> [[String: Any]] {
        if case let .list(parts) = expression.value, let head = parts.first,
           case let .symbol(formName) = head.value {
            switch formName {
            case "let":
                let prepared = try compileLetBindings(parts: parts, at: expression.location, environment: environment)
                var actions = prepared.actions
                let body = Array(parts.dropFirst(2))
                for bodyForm in body.dropLast() {
                    actions.append(contentsOf: try compileForm(bodyForm, environment: prepared.environment))
                }
                actions.append(contentsOf: try compileTailStep(
                    body.last!,
                    selfCallName: selfCallName,
                    parameterNames: parameterNames,
                    resultVariableName: resultVariableName,
                    environment: prepared.environment
                ))
                return actions

            case "if":
                let arguments = Array(parts.dropFirst())
                try requireArgumentCount(3, action: "if", arguments: arguments, at: expression.location)
                let condition = try compileValue(arguments[0], environment: environment)
                try requireIfCondition(condition, at: arguments[0].location)
                let trueActions = try compileTailStep(
                    arguments[1],
                    selfCallName: selfCallName,
                    parameterNames: parameterNames,
                    resultVariableName: resultVariableName,
                    environment: environment
                )
                let falseActions = try compileTailStep(
                    arguments[2],
                    selfCallName: selfCallName,
                    parameterNames: parameterNames,
                    resultVariableName: resultVariableName,
                    environment: environment
                )
                return lowerActionConditional(condition: condition, trueActions: trueActions, falseActions: falseActions)

            case selfCallName where parts.count - 1 == parameterNames.count:
                let arguments = Array(parts.dropFirst())
                var actions: [[String: Any]] = []
                var newValues: [ActionOutputReference] = []
                for argument in arguments {
                    let compiled = try compileValue(argument, environment: environment)
                    actions.append(contentsOf: compiled.actions)
                    newValues.append(emitValue(compiled.value, into: &actions))
                }
                for (name, value) in zip(parameterNames, newValues) {
                    actions.append(ShortcutPlist.action("is.workflow.actions.setvariable", parameters: [
                        "WFVariableName": name,
                        "WFInput": ShortcutPlist.actionOutputAttachment(name: value.name, uuid: value.uuid)
                    ]))
                }
                return actions

            default:
                break
            }
        }

        let compiled = try compileValue(expression, environment: environment)
        var actions = compiled.actions
        let output = emitValue(compiled.value, into: &actions)
        actions.append(ShortcutPlist.action("is.workflow.actions.setvariable", parameters: [
            "WFVariableName": resultVariableName,
            "WFInput": ShortcutPlist.actionOutputAttachment(name: output.name, uuid: output.uuid)
        ]))
        return actions
    }
}
