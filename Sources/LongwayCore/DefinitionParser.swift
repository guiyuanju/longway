struct FunctionParameter {
    let name: String
    let location: SourceLocation
}

struct FunctionDefinition {
    let name: String
    let nameLocation: SourceLocation
    let parameters: [FunctionParameter]
    let body: [Expression]
    let location: SourceLocation
}

/// Turns top-level `define` forms into `FunctionDefinition`s, rejecting anything
/// that cannot possibly become a standalone Shortcut before inference or codegen runs.
struct DefinitionParser {
    func parse(_ expressions: [Expression]) throws -> [FunctionDefinition] {
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

    private var reservedFunctionNames: Set<String> {
        [
            "define", "let", "if", "+", "-", "*", "/", "=", "<", "<=", ">", ">=",
            "and", "or", "not", "show-result", "notification", "open-url", "wait",
            "list", "length", "list-ref", "first", "last", "empty?",
            "dict", "dict-ref", "dict-set", "dict-keys", "dict-values",
            "string-append", "number->text", "split-lines", "split-whitespace", "split-text",
            "choose-from-list", "ask-text", "ask-number", "format-current-date"
        ]
    }
}
