import Foundation

/// The action catalog: source forms that lower directly to a Shortcuts action
/// rather than a value expression. Add new Shortcuts actions here.
extension FunctionCompiler {
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
        let text: [String: Any]
        switch value {
        case let .literalString(string):
            text = ShortcutPlist.textTokenString(string)
        case let .literalNumber(number):
            text = ShortcutPlist.textTokenString(ShortcutPlist.formatNumber(number))
        case let .literalBoolean(boolean):
            text = ShortcutPlist.textTokenString(boolean ? "#t" : "#f")
        case let .output(output):
            text = ShortcutPlist.actionOutputTokenString(name: output.name, uuid: output.uuid)
        }
        return [ShortcutPlist.action("is.workflow.actions.showresult", parameters: ["Text": text], uuid: nil)]
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
