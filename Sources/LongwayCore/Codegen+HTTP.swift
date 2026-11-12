import Foundation

extension FunctionCompiler {
    func compileHTTPRequest(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: CompileEnvironment
    ) throws -> CompiledValue {
        try requireArgumentCount(operation == "http-request" ? 2 : 1,
                                 action: operation, arguments: operands, at: location)
        let method: String
        if operation == "http-request" {
            guard case let .string(value) = operands[1].value,
                  ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(value) else {
                throw LongwayError("http-request method must be a literal GET, POST, PUT, PATCH, DELETE, or HEAD", at: operands[1].location)
            }
            method = value
        } else {
            method = operation == "http-get" ? "GET" : "POST"
        }
        let url = try compileValue(operands[0], environment: environment)
        guard typesAreCompatible(url.value.type, .text) else {
            throw LongwayError("\(operation) expects a text URL", at: operands[0].location)
        }
        if case let .literalString(value) = url.value {
            guard let parsed = URL(string: value),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host?.isEmpty == false else {
                throw LongwayError("\(operation) expects an absolute HTTP or HTTPS URL", at: operands[0].location)
            }
        }
        let uuid = UUID().uuidString
        let name = "Contents of URL"
        return CompiledValue(actions: url.actions + [ShortcutPlist.action(
            "is.workflow.actions.downloadurl", parameters: [
                "WFURL": tokenString(url.value),
                "WFHTTPMethod": method,
                "CustomOutputName": name
            ], uuid: uuid
        )], value: .output(ActionOutputReference(type: .any, name: name, uuid: uuid, isRuntimeTyped: false)))
    }
}
