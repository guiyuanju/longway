import Foundation
import LongwayCore

@main
struct LongwayCommand {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            fail("error: \(error.message)")
        } catch let error as LongwayError {
            fail(error.description)
        } catch {
            fail("error: \(error.localizedDescription)")
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "build":
            try build(rest)
        case "check":
            try check(rest)
        case "inspect-actions":
            try inspectActions(rest)
        case "help", "--help", "-h":
            printHelp()
        case "version", "--version":
            print("longway 0.1.0")
        default:
            throw CLIError("unknown command '\(command)'; run 'longway help'")
        }
    }

    private static func build(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            command: "build",
            flags: ["xml", "sign"],
            valued: ["output", "actions"],
            usage: "usage: longway build <file.longway> [-o directory] [--xml] "
                + "[--actions catalog.json]… [--sign[=anyone|people-who-know-me]]"
        )

        let signingMode = options.value("sign") ?? (options.has("sign") ? "people-who-know-me" : nil)
        if let signingMode, !["anyone", "people-who-know-me"].contains(signingMode) {
            throw CLIError("signing mode must be 'anyone' or 'people-who-know-me'")
        }

        let inputURL = URL(fileURLWithPath: options.input)
        let destination = options.value("output").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? inputURL.deletingPathExtension().appendingPathExtension("shortcuts")
        let compiled = try compileFile(
            inputURL,
            format: options.has("xml") ? .xml : .binary,
            actionCatalogPaths: options.all("actions")
        )

        // Sign the whole program before replacing anything on disk, so a
        // failure partway through leaves the destination as it was.
        let artifacts = try compiled.shortcuts.map { shortcut in
            (shortcut, try signingMode.map { try sign(shortcut.data, mode: $0) } ?? shortcut.data)
        }
        try prepareDirectory(destination)
        for (shortcut, data) in artifacts {
            try data.write(
                to: destination.appendingPathComponent(shortcut.name).appendingPathExtension("shortcut"),
                options: .atomic
            )
        }

        let actionCount = compiled.shortcuts.reduce(0) { $0 + $1.actionCount }
        let noun = compiled.shortcuts.count == 1 ? "function Shortcut" : "function Shortcuts"
        print(
            "Built \(compiled.shortcuts.count) \(signingMode == nil ? "unsigned" : "signed") \(noun) in "
            + "\(destination.path) (\(actionCount) Shortcut actions)"
        )
    }

    private static func check(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            command: "check",
            valued: ["actions"],
            usage: "usage: longway check <file.longway> [--actions catalog.json]…"
        )
        let compiled = try compileFile(
            URL(fileURLWithPath: options.input),
            format: .binary,
            actionCatalogPaths: options.all("actions")
        )
        let actionCount = compiled.shortcuts.reduce(0) { $0 + $1.actionCount }
        let names = compiled.shortcuts.map(\.name).joined(separator: ", ")
        let noun = compiled.shortcuts.count == 1 ? "function" : "functions"
        print("OK: \(compiled.shortcuts.count) \(noun) [\(names)] (\(actionCount) Shortcut actions)")
    }

    private static func inspectActions(_ arguments: [String]) throws {
        let options = try Options(
            arguments,
            command: "inspect-actions",
            flags: ["third-party-only"],
            valued: ["output"],
            usage: "usage: longway inspect-actions <file.shortcut> [-o directory] [--third-party-only]"
        )
        let thirdPartyOnly = options.has("third-party-only")
        let actions = try ShortcutActionExtractor().extract(from: URL(fileURLWithPath: options.input))
        let selected = thirdPartyOnly
            ? actions.filter { !$0.identifier.hasPrefix("is.workflow.actions.") }
            : actions

        for action in selected {
            print(String(format: "%02d  %@", action.index, action.identifier))
        }

        guard let outputPath = options.value("output") else {
            print("Found \(selected.count)\(thirdPartyOnly ? " third-party" : "") actions")
            return
        }

        // Extracted parameters can hold private workflow data, so this never
        // writes into a directory that already has something in it.
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try prepareDirectory(outputURL, mustBeEmpty: true)
        for action in selected {
            let safeIdentifier = action.identifier.replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "-",
                options: .regularExpression
            )
            try action.propertyListData.write(
                to: outputURL.appendingPathComponent(String(format: "%02d-%@.plist", action.index, safeIdentifier)),
                options: .atomic
            )
        }
        print("Wrote \(selected.count) action plists to \(outputURL.path)")
    }

    private static func compileFile(
        _ inputURL: URL,
        format: PropertyListSerialization.PropertyListFormat,
        actionCatalogPaths: [String]
    ) throws -> CompiledProgram {
        let source: String
        do {
            source = try String(contentsOf: inputURL, encoding: .utf8)
        } catch {
            throw CLIError("cannot read \(inputURL.path): \(error.localizedDescription)")
        }

        do {
            let catalog = try ActionCatalog(contentsOf: actionCatalogPaths.map { URL(fileURLWithPath: $0) })
            return try LongwayCompiler().compileProgram(source, format: format, catalog: catalog)
        } catch let error as LongwayError {
            throw CLIError("\(inputURL.path):\(error.description)")
        }
    }

    /// Creates `directory` when it is missing, and refuses a path that already
    /// exists as something other than a (optionally empty) directory.
    private static func prepareDirectory(_ directory: URL, mustBeEmpty: Bool = false) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return
        }
        guard isDirectory.boolValue else {
            throw CLIError("output path must be a directory")
        }
        guard try !mustBeEmpty || fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw CLIError("output directory must be empty")
        }
    }

    private static func sign(_ data: Data, mode: String) throws -> Data {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("longway-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let unsignedURL = temporaryDirectory.appendingPathComponent("unsigned.shortcut")
        let signedURL = temporaryDirectory.appendingPathComponent("signed.shortcut")
        try data.write(to: unsignedURL)

        try runTool(
            "/usr/bin/shortcuts",
            arguments: ["sign", "--mode", mode, "--input", unsignedURL.path, "--output", signedURL.path],
            failure: { "signing failed\($0). Try building without --sign." }
        )
        return try Data(contentsOf: signedURL)
    }

    private static func runTool(
        _ executable: String,
        arguments: [String],
        failure: (String) -> String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError("could not launch \(executable): \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(failure(detail.map { ": \($0)" } ?? ""))
        }
    }

    private static func printHelp() {
        print("""
        Longway — write Apple Shortcuts with Scheme-like syntax

        Usage:
          longway build <file.longway> [-o output-directory] [--xml]
                        [--actions catalog.json]…
                        [--sign[=anyone|people-who-know-me]]
          longway check <file.longway> [--actions catalog.json]…
          longway inspect-actions <file.shortcut> [-o directory] [--third-party-only]
          longway version

        Build creates one unsigned .shortcut per function in a .shortcuts directory.
        Use repeated --actions options to load declarative third-party action catalogs.
        Use --sign to call Apple's `shortcuts sign` command for every artifact.
        Inspect-actions reads unsigned or Apple-signed Shortcuts, lists their actions,
        and optionally writes each action as an XML property list.
        """)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

/// Every command takes the same shapes: valueless flags, options carrying a
/// value (`--name value` or `--name=value`, repeatable), and one positional
/// input path. A flag may also be given a value, which is how `--sign` and
/// `--sign=anyone` are both accepted.
private struct Options {
    let input: String
    private let flags: Set<String>
    private let values: [String: [String]]

    init(
        _ arguments: [String],
        command: String,
        flags knownFlags: Set<String> = [],
        valued: Set<String> = [],
        usage: String
    ) throws {
        var flags: Set<String> = []
        var values: [String: [String]] = [:]
        var input: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            guard argument.hasPrefix("-") else {
                guard input == nil else { throw CLIError("\(command) accepts one input file") }
                input = argument
                continue
            }

            let name: String
            let inlineValue: String?
            if let separator = argument.firstIndex(of: "=") {
                name = String(argument[argument.startIndex..<separator])
                inlineValue = String(argument[argument.index(after: separator)...])
            } else {
                name = argument
                inlineValue = nil
            }

            let key = name.drop(while: { $0 == "-" }) == "o" ? "output" : String(name.drop(while: { $0 == "-" }))
            if let inlineValue, valued.contains(key) || knownFlags.contains(key) {
                values[key, default: []].append(inlineValue)
            } else if valued.contains(key) {
                guard index < arguments.count else { throw CLIError("\(name) requires a value") }
                values[key, default: []].append(arguments[index])
                index += 1
            } else if knownFlags.contains(key) {
                flags.insert(key)
            } else {
                throw CLIError("unknown option '\(argument)'")
            }
        }

        guard let input else { throw CLIError(usage) }
        self.input = input
        self.flags = flags
        self.values = values
    }

    func has(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
}

private struct CLIError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
