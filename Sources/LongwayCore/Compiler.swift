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

/// Entry point for the compiler pipeline:
/// source → tokens → syntax → definitions → inferred signatures → Shortcut actions.
/// Each stage is an independent type (see DefinitionParser, SignatureInferrer,
/// FunctionCompiler); this struct only wires them together and serializes the result.
public struct LongwayCompiler {
    public init() {}

    public func compileProgram(
        _ source: String,
        format: PropertyListSerialization.PropertyListFormat = .binary,
        catalog: ActionCatalog = .empty
    ) throws -> CompiledProgram {
        var lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens: tokens)
        let expressions = try parser.parseProgram()
        let definitions = try DefinitionParser(
            additionalReservedNames: catalog.actionNames
        ).parse(expressions)
        let signatures = try SignatureInferrer(catalog: catalog).infer(definitions)
        let compiler = FunctionCompiler(signatures: signatures, catalog: catalog)

        let shortcuts = try definitions.map { definition in
            let workflow = try compiler.compile(definition)
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
        format: PropertyListSerialization.PropertyListFormat = .binary,
        catalog: ActionCatalog = .empty
    ) throws -> CompiledShortcut {
        let program = try compileProgram(source, format: format, catalog: catalog)
        guard program.shortcuts.count == 1, let shortcut = program.shortcuts.first else {
            throw LongwayError(
                "source defines \(program.shortcuts.count) functions; use compileProgram to compile all functions",
                at: SourceLocation(line: 1, column: 1)
            )
        }
        return shortcut
    }
}
