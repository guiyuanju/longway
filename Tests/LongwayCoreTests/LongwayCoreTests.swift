import Foundation
import XCTest
@testable import LongwayCore

final class LongwayCoreTests: XCTestCase {
    func testShowResultEmbedsStringLiteralDirectly() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Hello Longway"
          (show-result "Hello from Longway!"))
        """)

        XCTAssertEqual(result.name, "Hello Longway")
        XCTAssertEqual(result.actionCount, 1)

        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.showresult")
        XCTAssertEqual(propertyList["WFWorkflowTypes"] as? [String], [])
        XCTAssertEqual(propertyList["WFWorkflowHasShortcutInputVariables"] as? Bool, false)

        let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let text = try XCTUnwrap(parameters["Text"] as? [String: Any])
        XCTAssertEqual(text["WFSerializationType"] as? String, "WFTextTokenString")
        let value = try XCTUnwrap(text["Value"] as? [String: Any])
        XCTAssertEqual(value["string"] as? String, "Hello from Longway!")
        XCTAssertEqual((value["attachmentsByRange"] as? [String: Any])?.count, 0)
    }

    func testLetMaterializesTextAndShowResultReferencesItsUUID() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Hello Longway"
          (let ((content "Hello from Longway!"))
            (show-result content)))
        """)

        XCTAssertEqual(result.actionCount, 2)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.gettext")
        XCTAssertEqual(actions[1]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.showresult")

        let textParameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let textActionUUID = try XCTUnwrap(textParameters["UUID"] as? String)
        let showParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let showText = try XCTUnwrap(showParameters["Text"] as? [String: Any])
        let showValue = try XCTUnwrap(showText["Value"] as? [String: Any])
        XCTAssertEqual(showValue["string"] as? String, "\u{FFFC}")
        let attachments = try XCTUnwrap(showValue["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["Type"] as? String, "ActionOutput")
        XCTAssertEqual(attachment["OutputName"] as? String, "Text")
        XCTAssertEqual(attachment["OutputUUID"] as? String, textActionUUID)
    }

    func testOpenURLExpandsToURLAndOpenActions() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Website"
          (open-url "https://example.com"))
        """)

        XCTAssertEqual(result.actionCount, 2)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.url")
        XCTAssertEqual(actions[1]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.openurl")
    }

    func testLetRejectsUnknownVariable() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (show-result missing))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "unknown variable 'missing'")
        }
    }

    func testLetRejectsDuplicateBindings() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (let ((content "one") (content "two"))
            (show-result content)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "duplicate let binding 'content'")
        }
    }

    func testLetInitializersUseOuterScope() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (let ((first "one") (second first))
            (show-result second)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "unknown variable 'first'")
        }
    }

    func testShowResultRequiresOneArgument() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (show-result))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "show-result expects 1 argument, got 0")
        }
    }

    func testReportsSourceLocationForUnknownAction() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (teleport "home"))
        """)) { error in
            guard let error = error as? LongwayError else {
                return XCTFail("Expected LongwayError, got \(error)")
            }
            XCTAssertEqual(error.location, SourceLocation(line: 2, column: 4))
            XCTAssertEqual(error.message, "unknown action 'teleport'")
        }
    }

    func testRejectsTrailingTopLevelExpression() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("(shortcut \"One\" (text \"1\")) (text \"2\")")) { error in
            XCTAssertTrue(String(describing: error).contains("only one top-level expression"))
        }
    }

    func testStringEscapesAndComments() throws {
        var lexer = Lexer(source: "; ignored\n(text \"a\\tb\\\"c\" #t 2.5)")
        let tokens = try lexer.tokenize()
        XCTAssertEqual(tokens[0].kind, .leftParen)
        XCTAssertEqual(tokens[1].kind, .symbol("text"))
        XCTAssertEqual(tokens[2].kind, .string("a\tb\"c"))
        XCTAssertEqual(tokens[3].kind, .boolean(true))
        XCTAssertEqual(tokens[4].kind, .number(2.5))
    }
}
