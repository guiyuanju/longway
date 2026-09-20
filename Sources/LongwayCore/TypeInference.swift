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
        let formName = parts.first?.symbol == "let*" ? "let*" : "let"
        let isSequential = formName == "let*"
        guard parts.count >= 3 else {
            throw LongwayError("\(formName) expects bindings and at least one body form", at: location)
        }
        guard case let .list(bindings) = parts[1].value else {
            throw LongwayError("\(formName) bindings must be a list", at: parts[1].location)
        }

        var bodyEnvironment = environment
        var localBindings: [String: Int] = [:]
        var names = Set<String>()
        for binding in bindings {
            guard case let .list(pair) = binding.value, pair.count == 2 else {
                throw LongwayError("\(formName) binding must contain a name and value", at: binding.location)
            }
            guard case let .symbol(name) = pair[0].value else {
                throw LongwayError("\(formName) binding name must be a symbol", at: pair[0].location)
            }
            if !isSequential, !names.insert(name).inserted {
                throw LongwayError("duplicate let binding '\(name)'", at: pair[0].location)
            }
            let initializerEnvironment = isSequential ? bodyEnvironment : environment
            let value = try inferValue(pair[1], environment: initializerEnvironment, inference: inference)
            if isSequential {
                bodyEnvironment.variables[name] = value
            } else {
                localBindings[name] = value
            }
        }

        if !isSequential {
            bodyEnvironment.variables.merge(localBindings) { _, local in local }
        }
        return bodyEnvironment
    }

    /// List elements are untyped, so every read returns a fresh unconstrained
    /// variable that whatever consumes it may bind. Only the list operand and
    /// `list-ref`'s index carry constraints.
    private func inferListOperation(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> Int {
        if operation == "list" {
            for operand in operands {
                let element = try inferValue(operand, environment: environment, inference: inference)
                if let bound = inference.boundType(element), bound == .list || bound == .dictionary {
                    throw LongwayError("list elements cannot be \(bound.pluralName)", at: operand.location)
                }
            }
            return inference.makeVariable(boundTo: .list)
        }

        try requireArgumentCount(
            operation == "list-ref" ? 2 : 1,
            action: operation,
            arguments: operands,
            at: location
        )
        let list = try inferValue(operands[0], environment: environment, inference: inference)
        try inference.constrain(
            list,
            to: .list,
            message: "\(operation) expects a list",
            at: operands[0].location
        )
        if operation == "list-ref" {
            let index = try inferValue(operands[1], environment: environment, inference: inference)
            try inference.constrain(
                index,
                to: .number,
                message: "list-ref expects a number index",
                at: operands[1].location
            )
        }

        switch operation {
        case "length":
            return inference.makeVariable(boundTo: .number)
        case "empty?":
            return inference.makeVariable(boundTo: .boolean)
        default:
            return inference.makeVariable()
        }
    }

    /// Dictionary values are untyped in the same way list elements are, so a
    /// `dict-ref` returns a fresh unconstrained variable. Keys are always text.
    private func inferDictionaryOperation(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> Int {
        if operation == "dict" {
            guard operands.count.isMultiple(of: 2) else {
                throw LongwayError(
                    "dict expects alternating keys and values, got \(operands.count) forms",
                    at: location
                )
            }
            for pair in stride(from: 0, to: operands.count, by: 2) {
                let key = try inferValue(operands[pair], environment: environment, inference: inference)
                try inference.constrain(
                    key,
                    to: .text,
                    message: "dict expects a text key",
                    at: operands[pair].location
                )
                _ = try inferValue(operands[pair + 1], environment: environment, inference: inference)
            }
            return inference.makeVariable(boundTo: .dictionary)
        }

        try requireArgumentCount(
            ["dict-set": 3, "dict-ref": 2][operation] ?? 1,
            action: operation,
            arguments: operands,
            at: location
        )
        let dictionary = try inferValue(operands[0], environment: environment, inference: inference)
        try inference.constrain(
            dictionary,
            to: .dictionary,
            message: "\(operation) expects a dictionary",
            at: operands[0].location
        )
        if operation == "dict-keys" || operation == "dict-values" {
            return inference.makeVariable(boundTo: .list)
        }

        let key = try inferValue(operands[1], environment: environment, inference: inference)
        try inference.constrain(
            key,
            to: .text,
            message: "\(operation) expects a text key",
            at: operands[1].location
        )
        if operation == "dict-ref" {
            return inference.makeVariable()
        }

        let value = try inferValue(operands[2], environment: environment, inference: inference)
        if let bound = inference.boundType(value) {
            try requireStorableInDictionaryField(bound, at: operands[2].location)
        }
        return inference.makeVariable(boundTo: .dictionary)
    }

    private func inferTextOperation(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> Int {
        switch operation {
        case "string-append":
            for operand in operands {
                let value = try inferValue(operand, environment: environment, inference: inference)
                try inference.constrain(
                    value,
                    to: .text,
                    message: "string-append expects text operands",
                    at: operand.location
                )
            }
        case "number->text":
            try requireArgumentCount(1, action: operation, arguments: operands, at: location)
            let value = try inferValue(operands[0], environment: environment, inference: inference)
            try inference.constrain(
                value,
                to: .number,
                message: "number->text expects a number",
                at: operands[0].location
            )
        case "split-lines", "split-whitespace":
            try requireArgumentCount(1, action: operation, arguments: operands, at: location)
            let value = try inferValue(operands[0], environment: environment, inference: inference)
            try inference.constrain(
                value,
                to: .text,
                message: "\(operation) expects text",
                at: operands[0].location
            )
            return inference.makeVariable(boundTo: .list)
        case "split-text":
            try requireArgumentCount(2, action: operation, arguments: operands, at: location)
            for operand in operands {
                let value = try inferValue(operand, environment: environment, inference: inference)
                try inference.constrain(
                    value,
                    to: .text,
                    message: "split-text expects text operands",
                    at: operand.location
                )
            }
            return inference.makeVariable(boundTo: .list)
        default:
            preconditionFailure("unknown text operation")
        }
        return inference.makeVariable(boundTo: .text)
    }

    private func inferInteractiveOperation(
        _ operation: String,
        operands: [Expression],
        at location: SourceLocation,
        environment: InferenceEnvironment,
        inference: TypeInference
    ) throws -> Int {
        switch operation {
        case "choose-from-list":
            try requireArgumentCount(2, action: operation, arguments: operands, at: location)
            let list = try inferValue(operands[0], environment: environment, inference: inference)
            try inference.constrain(
                list,
                to: .list,
                message: "choose-from-list expects a list",
                at: operands[0].location
            )
            let prompt = try inferValue(operands[1], environment: environment, inference: inference)
            try inference.constrain(
                prompt,
                to: .text,
                message: "choose-from-list expects a text prompt",
                at: operands[1].location
            )
            return inference.makeVariable()
        case "ask-text", "ask-number", "format-current-date":
            try requireArgumentCount(1, action: operation, arguments: operands, at: location)
            let text = try inferValue(operands[0], environment: environment, inference: inference)
            try inference.constrain(
                text,
                to: .text,
                message: "\(operation) expects text",
                at: operands[0].location
            )
            return inference.makeVariable(boundTo: operation == "ask-number" ? .number : .text)
        default:
            preconditionFailure("unknown interactive operation")
        }
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
            if listOperations.contains(operation) {
                return try inferListOperation(
                    operation,
                    operands: operands,
                    at: expression.location,
                    environment: environment,
                    inference: inference
                )
            }
            if dictionaryOperations.contains(operation) {
                return try inferDictionaryOperation(
                    operation,
                    operands: operands,
                    at: expression.location,
                    environment: environment,
                    inference: inference
                )
            }
            if textOperations.contains(operation) {
                return try inferTextOperation(
                    operation,
                    operands: operands,
                    at: expression.location,
                    environment: environment,
                    inference: inference
                )
            }
            if interactiveOperations.contains(operation) {
                return try inferInteractiveOperation(
                    operation,
                    operands: operands,
                    at: expression.location,
                    environment: environment,
                    inference: inference
                )
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
