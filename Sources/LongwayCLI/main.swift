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
            case "--sign":
                signingMode = "people-who-know-me"
                if index + 1 < arguments.count, ["anyone", "people-who-know-me"].contains(arguments[index + 1]) {
                    index += 1
                    signingMode = arguments[index]
                }
            default:
                if argument.hasPrefix("--sign=") {
                    signingMode = String(argument.dropFirst("--sign=".count))
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
        let destination = outputPath.map { URL(fileURLWithPath: $0) }
            ?? inputURL.deletingPathExtension().appendingPathExtension("shortcut")
        let compiled = try compileFile(inputURL, format: format)

        if let signingMode {
            try sign(compiled.data, to: destination, mode: signingMode)
            print("Built and signed \(destination.path) (\(compiled.actionCount) Shortcut actions)")
        } else {
            try compiled.data.write(to: destination, options: .atomic)
            print("Built \(destination.path) (\(compiled.actionCount) Shortcut actions, unsigned)")
        }
    }

    private static func check(_ arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw CLIError("usage: longway check <file.longway>")
        }
        let compiled = try compileFile(URL(fileURLWithPath: arguments[0]), format: .binary)
        print("OK: \(compiled.name) (\(compiled.actionCount) Shortcut actions)")
    }

    private static func compileFile(
        _ inputURL: URL,
        format: PropertyListSerialization.PropertyListFormat
    ) throws -> CompiledShortcut {
        let source: String
        do {
            source = try String(contentsOf: inputURL, encoding: .utf8)
        } catch {
            throw CLIError("cannot read \(inputURL.path): \(error.localizedDescription)")
        }

        do {
            return try LongwayCompiler().compile(source, format: format)
        } catch let error as LongwayError {
            throw CLIError("\(inputURL.path):\(error.description)")
        }
    }

    private static func sign(_ data: Data, to destination: URL, mode: String) throws {
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

        let signedData = try Data(contentsOf: signedURL)
        try signedData.write(to: destination, options: .atomic)
    }

    private static func printHelp() {
        print("""
        Longway — write Apple Shortcuts with Scheme-like syntax

        Usage:
          longway build <file.longway> [-o output.shortcut] [--xml]
                        [--sign[=anyone|people-who-know-me]]
          longway check <file.longway>
          longway version

        Build creates an unsigned binary .shortcut by default. Use --sign to call
        Apple's `shortcuts sign` command and create an importable shared file.
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
