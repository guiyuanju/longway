import Foundation
import Security

public struct ExtractedShortcutAction {
    public let index: Int
    public let identifier: String
    public let propertyListData: Data
}

public struct ShortcutActionExtractor {
    public init() {}

    public func extract(from shortcutURL: URL) throws -> [ExtractedShortcutAction] {
        let input: Data
        do {
            input = try Data(contentsOf: shortcutURL)
        } catch {
            throw ShortcutExtractionError("cannot read \(shortcutURL.path): \(error.localizedDescription)")
        }

        let workflowData: Data
        if input.starts(with: Data("AEA1".utf8)) {
            workflowData = try extractSignedWorkflow(input, sourceURL: shortcutURL)
        } else {
            workflowData = input
        }
        return try parseActions(workflowData)
    }

    private func extractSignedWorkflow(_ archive: Data, sourceURL: URL) throws -> Data {
        guard archive.count >= 12 else {
            throw ShortcutExtractionError("\(sourceURL.path) has a truncated AEA header")
        }
        let authDataLength = archive[8..<12].enumerated().reduce(0) { result, pair in
            result | (Int(pair.element) << (pair.offset * 8))
        }
        guard authDataLength > 0, 12 + authDataLength <= archive.count else {
            throw ShortcutExtractionError("\(sourceURL.path) has an invalid AEA authentication header")
        }

        let authData = archive.subdata(in: 12..<(12 + authDataLength))
        let authPropertyList: Any
        do {
            authPropertyList = try PropertyListSerialization.propertyList(from: authData, format: nil)
        } catch {
            throw ShortcutExtractionError("cannot read the AEA authentication header: \(error.localizedDescription)")
        }
        guard let authDictionary = authPropertyList as? [String: Any],
              let certificateChain = authDictionary["SigningCertificateChain"] as? [Data],
              let leafCertificateData = certificateChain.first
        else {
            throw ShortcutExtractionError("AEA archive does not contain a signing certificate chain")
        }

        let publicKeyPEM = try publicKeyPEM(from: leafCertificateData)
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("longway-inspect-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let archiveURL = temporaryDirectory.appendingPathComponent("input.shortcut")
        let publicKeyURL = temporaryDirectory.appendingPathComponent("signing-key.pem")
        let payloadURL = temporaryDirectory.appendingPathComponent("payload.aar")
        let extractedDirectory = temporaryDirectory.appendingPathComponent("workflow", isDirectory: true)
        try archive.write(to: archiveURL)
        try publicKeyPEM.write(to: publicKeyURL, atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)

        try runTool(
            "/usr/bin/aea",
            arguments: [
                "decrypt", "-i", archiveURL.path, "-o", payloadURL.path,
                "-sign-pub", publicKeyURL.path
            ],
            purpose: "decrypting signed Shortcut"
        )
        try runTool(
            "/usr/bin/aa",
            arguments: ["extract", "-i", payloadURL.path, "-d", extractedDirectory.path],
            purpose: "extracting signed Shortcut payload"
        )

        let workflowURL = extractedDirectory.appendingPathComponent("Shortcut.wflow")
        guard fileManager.fileExists(atPath: workflowURL.path) else {
            throw ShortcutExtractionError("signed Shortcut payload does not contain Shortcut.wflow")
        }
        do {
            return try Data(contentsOf: workflowURL)
        } catch {
            throw ShortcutExtractionError("cannot read extracted Shortcut.wflow: \(error.localizedDescription)")
        }
    }

    private func publicKeyPEM(from certificateData: Data) throws -> String {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let key = SecCertificateCopyKey(certificate)
        else {
            throw ShortcutExtractionError("cannot read the Shortcut signing certificate")
        }
        var keyError: Unmanaged<CFError>?
        guard let externalRepresentation = SecKeyCopyExternalRepresentation(key, &keyError) as Data? else {
            let detail = keyError?.takeRetainedValue().localizedDescription ?? "unknown Security framework error"
            throw ShortcutExtractionError("cannot export the Shortcut signing public key: \(detail)")
        }
        guard externalRepresentation.count == 65, externalRepresentation.first == 0x04 else {
            throw ShortcutExtractionError("Shortcut signing certificate does not use a supported P-256 public key")
        }

        // SubjectPublicKeyInfo for an uncompressed P-256 point. `aea` accepts
        // this standard PEM representation for `-sign-pub`.
        let algorithmIdentifier: [UInt8] = [
            0x30, 0x13,
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07
        ]
        var subjectPublicKeyInfo: [UInt8] = [0x30, 0x59]
        subjectPublicKeyInfo.append(contentsOf: algorithmIdentifier)
        subjectPublicKeyInfo.append(contentsOf: [0x03, 0x42, 0x00])
        subjectPublicKeyInfo.append(contentsOf: externalRepresentation)

        let base64 = Data(subjectPublicKeyInfo).base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----\n"
    }

    private func parseActions(_ workflowData: Data) throws -> [ExtractedShortcutAction] {
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: workflowData, format: nil)
        } catch {
            throw ShortcutExtractionError("Shortcut workflow is not a property list: \(error.localizedDescription)")
        }
        guard let workflow = propertyList as? [String: Any],
              let actions = workflow["WFWorkflowActions"] as? [[String: Any]]
        else {
            throw ShortcutExtractionError("property list does not contain WFWorkflowActions")
        }

        return try actions.enumerated().map { index, action in
            guard let identifier = action["WFWorkflowActionIdentifier"] as? String else {
                throw ShortcutExtractionError("action \(index) has no WFWorkflowActionIdentifier")
            }
            let data: Data
            do {
                data = try PropertyListSerialization.data(
                    fromPropertyList: action,
                    format: .xml,
                    options: 0
                )
            } catch {
                throw ShortcutExtractionError("cannot serialize action \(index): \(error.localizedDescription)")
            }
            return ExtractedShortcutAction(index: index, identifier: identifier, propertyListData: data)
        }
    }

    private func runTool(_ executable: String, arguments: [String], purpose: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShortcutExtractionError("required Apple tool is unavailable: \(executable)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ShortcutExtractionError("could not launch \(executable) while \(purpose): \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShortcutExtractionError("failed while \(purpose)\(detail.map { ": \($0)" } ?? "")")
        }
    }
}

public struct ShortcutExtractionError: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
