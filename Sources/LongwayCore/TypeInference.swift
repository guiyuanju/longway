struct ParameterSignature {
    let name: String
    let type: ValueType
}

struct FunctionSignature {
    let name: String
    let parameters: [ParameterSignature]
    let returnType: ValueType
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

/// Infers parameter and return types for every definition by walking each body
/// against a shared union-find, re-drafting signatures until they reach a fixpoint.
/// This lets mutually recursive functions constrain each other's types regardless
/// of definition order.
struct SignatureInferrer {
    let catalog: ActionCatalog

    init(catalog: ActionCatalog = .empty) {
        self.catalog = catalog
    }

    func infer(
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

        if formName == "let" || formName == "let*" {
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
        if let externalAction = catalog.actions[formName] {
            _ = try inferExternalAction(
                externalAction,
                operands: Array(parts.dropFirst()),
                at: expression.location,
                environment: environment,
                inference: inference,
                requireResult: false
            )
            return
        }
        if environment.functions[formName] != nil {
            _ = try inferValue(expression, environment: environment, inference: inference)
            return
        }

        let arguments = Array(parts.dropFirst())
        if formName == "show-result" {
            try requireArgumentCount(1, action: formName, arguments: arguments, at: expression.location)
            _ = try inferValue(arguments[0], environment: environment, inference: inference)
            return
        }
        // The remaining statement forms take literal operands only, which
        // codegen checks when it lowers them.
        guard builtinStatementForms.contains(formName) else {
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
            if formName == "let" || formName == "let*" {
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
        let form = try LetForm(parts, at: location)
        var bodyEnvironment = environment
        var localBindings: [String: Int] = [:]

        for binding in form.bindings {
            // A `let` initializer sees the outer scope; a `let*` initializer
            // sees the bindings before it.
            let initializerEnvironment = form.isSequential ? bodyEnvironment : environment
            let value = try inferValue(
                binding.value,
                environment: initializerEnvironment,
                inference: inference
            )
            if form.isSequential {
                bodyEnvironment.variables[binding.name] = value
            } else {
                localBindings[binding.name] = value
            }
        }

        bodyEnvironment.variables.merge(localBindings) { _, local in local }
        return bodyEnvironment
    }

    /// Checks one built-in call against its declared signature: the arity and
    /// operand types come from the `builtins` table, so this is the only place
    /// inference needs to know how any of them are used. Forms whose result is
    /// `.any` answer a fresh unconstrained variable, which is what makes a list
    /// element or a dictionary value take its type from whatever reads it.
    private func inferBuiltin(
        _ operation: String,
        _ builtin: Builtin,
        operands: [Expression],
        at location: SourceLocation,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> Int {
        let expected = try builtin.operands.check(operation, operands: operands, at: location)
        var variables: [Int] = []
        for (operand, rule) in zip(operands, expected) {
            let variable = try inferValue(operand, environment: environment, inference: inference)
            if rule.type != .any {
                try inference.constrain(
                    variable,
                    to: rule.type,
                    message: "\(operation) \(rule.expectation)",
                    at: operand.location
                )
            }
            variables.append(variable)
        }
        try checkContainerRules(operation, operands: operands, variables: variables, inference: inference)
        return builtin.result == .any
            ? inference.makeVariable()
            : inference.makeVariable(boundTo: builtin.result)
    }

    /// The rules a plain type signature cannot express. A `WFItems` entry
    /// flattens a list to newline-joined text and a dictionary to JSON, so
    /// neither can be stored in one.
    private func checkContainerRules(
        _ operation: String,
        operands: [Expression],
        variables: [Int],
        inference: TypeInference
    ) throws {
        switch operation {
        case "list":
            for (operand, variable) in zip(operands, variables) {
                guard let bound = inference.boundType(variable),
                      bound == .list || bound == .dictionary
                else { continue }
                throw LongwayError("list elements cannot be \(bound.pluralName)", at: operand.location)
            }
        case "dict-set":
            guard let bound = inference.boundType(variables[2]) else { return }
            try requireStorableInDictionaryField(bound, at: operands[2].location)
        default:
            return
        }
    }

    private func inferExternalAction(
        _ action: ExternalActionDefinition,
        operands: [Expression],
        at location: SourceLocation,
        environment: InferenceEnvironment,
        inference: TypeInference,
        requireResult: Bool
    ) throws -> Int? {
        try requireArgumentCount(
            action.arguments.count,
            action: action.name,
            arguments: operands,
            at: location
        )
        for (index, pair) in zip(operands, action.arguments).enumerated() {
            let value = try inferValue(pair.0, environment: environment, inference: inference)
            if pair.1.type != .any {
                try inference.constrain(
                    value,
                    to: pair.1.type,
                    message: "\(action.name) argument \(index + 1) expects \(pair.1.type.name)",
                    at: pair.0.location
                )
            }
        }
        guard let result = action.result else {
            if requireResult {
                throw LongwayError("external action '\(action.name)' does not produce a value", at: location)
            }
            return nil
        }
        return result.type == .any
            ? inference.makeVariable()
            : inference.makeVariable(boundTo: result.type)
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

            if operation == "let" || operation == "let*" {
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
            if let builtin = builtins[operation] {
                return try inferBuiltin(
                    operation,
                    builtin,
                    operands: operands,
                    at: expression.location,
                    environment: environment,
                    inference: inference
                )
            }
            if let externalAction = catalog.actions[operation] {
                return try inferExternalAction(
                    externalAction,
                    operands: operands,
                    at: expression.location,
                    environment: environment,
                    inference: inference,
                    requireResult: true
                )!
            }
            if let function = environment.functions[operation] {
                guard operands.count == function.parameters.count else {
                    throw LongwayError(
                        argumentCountMessage(
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

}

/// Union-find over type variables. `constrain` binds a variable to a concrete type;
/// `unify` merges two variables so later binding either one binds both.
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
