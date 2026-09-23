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

        switch command {
        case "build":
            try build(Array(arguments.dropFirst()))
        case "check":
            try check(Array(arguments.dropFirst()))
        case "inspect-actions":
            try inspectActions(Array(arguments.dropFirst()))
        case "help", "--help", "-h":
            printHelp()
        case "version", "--version":
            print("longway 0.1.0")
        default:
            throw CLIError("unknown command '\(command)'; run 'longway help'")
        }
    }

    private static func build(_ arguments: [String]) throws {
        var inputPath: String?
        var outputPath: String?
        var format: PropertyListSerialization.PropertyListFormat = .binary
        var signingMode: String?
        var actionCatalogPaths: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("\(argument) requires a path")
                }
                outputPath = arguments[index]
            case "--xml":
                format = .xml
            case "--actions":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("--actions requires a JSON catalog path")
                }
                actionCatalogPaths.append(arguments[index])
            case "--sign":
                signingMode = "people-who-know-me"
                if index + 1 < arguments.count, ["anyone", "people-who-know-me"].contains(arguments[index + 1]) {
                    index += 1
                    signingMode = arguments[index]
                }
            default:
                if argument.hasPrefix("--sign=") {
                    signingMode = String(argument.dropFirst("--sign=".count))
                } else if argument.hasPrefix("--actions=") {
                    actionCatalogPaths.append(String(argument.dropFirst("--actions=".count)))
                } else if argument.hasPrefix("-") {
                    throw CLIError("unknown option '\(argument)'")
                } else if inputPath == nil {
                    inputPath = argument
                } else {
                    throw CLIError("build accepts one input file")
                }
            }
            index += 1
        }

        guard let inputPath else {
            throw CLIError("build requires an input file")
        }
        if let signingMode, !["anyone", "people-who-know-me"].contains(signingMode) {
            throw CLIError("signing mode must be 'anyone' or 'people-who-know-me'")
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let destination = outputPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? inputURL.deletingPathExtension().appendingPathExtension("shortcuts")
        let compiled = try compileFile(
            inputURL,
            format: format,
            actionCatalogPaths: actionCatalogPaths
        )
        let artifacts = try compiled.shortcuts.map { shortcut in
            let data = try signingMode.map { try sign(shortcut.data, mode: $0) } ?? shortcut.data
            return (shortcut, data)
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CLIError("output path must be a directory")
            }
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        for (shortcut, data) in artifacts {
            let outputURL = destination
                .appendingPathComponent(shortcut.name)
                .appendingPathExtension("shortcut")
            try data.write(to: outputURL, options: .atomic)
        }
        let actionCount = compiled.shortcuts.reduce(0) { $0 + $1.actionCount }
        let signingDescription = signingMode == nil ? "unsigned" : "signed"
        let noun = compiled.shortcuts.count == 1 ? "function Shortcut" : "function Shortcuts"
        print(
            "Built \(compiled.shortcuts.count) \(signingDescription) \(noun) in " +
            "\(destination.path) (\(actionCount) Shortcut actions)"
        )
    }

    private static func check(_ arguments: [String]) throws {
        var inputPath: String?
        var actionCatalogPaths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--actions" {
                index += 1
                guard index < arguments.count else {
                    throw CLIError("--actions requires a JSON catalog path")
                }
                actionCatalogPaths.append(arguments[index])
            } else if argument.hasPrefix("--actions=") {
                actionCatalogPaths.append(String(argument.dropFirst("--actions=".count)))
            } else if argument.hasPrefix("-") {
                throw CLIError("unknown option '\(argument)'")
            } else if inputPath == nil {
                inputPath = argument
            } else {
                throw CLIError("check accepts one input file")
            }
            index += 1
        }
        guard let inputPath else {
            throw CLIError("usage: longway check <file.longway> [--actions catalog.json]")
        }
        let compiled = try compileFile(
            URL(fileURLWithPath: inputPath),
            format: .binary,
            actionCatalogPaths: actionCatalogPaths
        )
        let actionCount = compiled.shortcuts.reduce(0) { $0 + $1.actionCount }
        let names = compiled.shortcuts.map(\.name).joined(separator: ", ")
        let noun = compiled.shortcuts.count == 1 ? "function" : "functions"
        print("OK: \(compiled.shortcuts.count) \(noun) [\(names)] (\(actionCount) Shortcut actions)")
    }

    private static func inspectActions(_ arguments: [String]) throws {
        var inputPath: String?
        var outputPath: String?
        var thirdPartyOnly = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("\(argument) requires a directory")
                }
                outputPath = arguments[index]
            case "--third-party-only":
                thirdPartyOnly = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError("unknown option '\(argument)'")
                } else if inputPath == nil {
                    inputPath = argument
                } else {
                    throw CLIError("inspect-actions accepts one input file")
                }
            }
            index += 1
        }

        guard let inputPath else {
            throw CLIError("usage: longway inspect-actions <file.shortcut> [-o directory] [--third-party-only]")
        }
        let actions = try ShortcutActionExtractor().extract(from: URL(fileURLWithPath: inputPath))
        let selected = thirdPartyOnly
            ? actions.filter { !$0.identifier.hasPrefix("is.workflow.actions.") }
            : actions

        for action in selected {
            print(String(format: "%02d  %@", action.index, action.identifier))
        }

        guard let outputPath else {
            let qualifier = thirdPartyOnly ? " third-party" : ""
            print("Found \(selected.count)\(qualifier) actions")
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CLIError("output path must be a directory")
            }
            guard try fileManager.contentsOfDirectory(atPath: outputURL.path).isEmpty else {
                throw CLIError("output directory must be empty")
            }
        } else {
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        }

        for action in selected {
            let safeIdentifier = action.identifier.replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "-",
                options: .regularExpression
            )
            let filename = String(format: "%02d-%@.plist", action.index, safeIdentifier)
            try action.propertyListData.write(
                to: outputURL.appendingPathComponent(filename),
                options: .atomic
            )
        }
        print("Wrote \(selected.count) action plists to \(outputURL.path)")
    }

    private static func compileFile(
        _ inputURL: URL,
        format: PropertyListSerialization.PropertyListFormat,
        actionCatalogPaths: [String] = []
    ) throws -> CompiledProgram {
        let source: String
        do {
            source = try String(contentsOf: inputURL, encoding: .utf8)
        } catch {
            throw CLIError("cannot read \(inputURL.path): \(error.localizedDescription)")
        }

        do {
            let catalog = try ActionCatalog(
                contentsOf: actionCatalogPaths.map { URL(fileURLWithPath: $0) }
            )
            return try LongwayCompiler().compileProgram(
                source,
                format: format,
                catalog: catalog
            )
        } catch let error as LongwayError {
            throw CLIError("\(inputURL.path):\(error.description)")
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = [
            "sign", "--mode", mode,
            "--input", unsignedURL.path,
            "--output", signedURL.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError("could not launch Apple’s shortcuts signer: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError("signing failed\(detail.map { ": \($0)" } ?? ""). Try building without --sign.")
        }

        return try Data(contentsOf: signedURL)
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

private struct CLIError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
