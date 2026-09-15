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

    func testShowResultEmbedsBooleanLiteralDirectly() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Boolean"
          (show-result #t))
        """)

        XCTAssertEqual(result.actionCount, 1)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let text = try XCTUnwrap(parameters["Text"] as? [String: Any])
        let value = try XCTUnwrap(text["Value"] as? [String: Any])
        XCTAssertEqual(value["string"] as? String, "#t")
    }

    func testBooleanLetBindingMaterializesTextVariable() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Boolean"
          (let ((enabled #t))
            (show-result enabled)))
        """)

        XCTAssertEqual(result.actionCount, 2)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.gettext")
        let textParameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let textUUID = try XCTUnwrap(textParameters["UUID"] as? String)
        let text = try XCTUnwrap(textParameters["WFTextActionText"] as? [String: Any])
        let textValue = try XCTUnwrap(text["Value"] as? [String: Any])
        XCTAssertEqual(textValue["string"] as? String, "#t")

        let showParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let showText = try XCTUnwrap(showParameters["Text"] as? [String: Any])
        let showValue = try XCTUnwrap(showText["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(showValue["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["OutputUUID"] as? String, textUUID)
    }

    func testNotLowersToIfOtherwiseEndIfAndReferencesIfResult() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Boolean"
          (show-result (not #t)))
        """)

        XCTAssertEqual(result.actionCount, 7)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.gettext",
            "is.workflow.actions.conditional",
            "is.workflow.actions.gettext",
            "is.workflow.actions.conditional",
            "is.workflow.actions.gettext",
            "is.workflow.actions.conditional",
            "is.workflow.actions.showresult"
        ])

        let inputText = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let inputUUID = try XCTUnwrap(inputText["UUID"] as? String)
        let start = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(start["WFControlFlowMode"] as? Int, 0)
        XCTAssertEqual(start["WFCondition"] as? Int, 4)
        XCTAssertEqual(start["WFConditionalActionString"] as? String, "#t")
        let input = try XCTUnwrap(start["WFInput"] as? [String: Any])
        let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
        XCTAssertEqual(inputValue["OutputUUID"] as? String, inputUUID)

        XCTAssertEqual(textLiteral(in: actions[2]), "#f")
        XCTAssertEqual(textLiteral(in: actions[4]), "#t")

        let otherwise = try XCTUnwrap(actions[3]["WFWorkflowActionParameters"] as? [String: Any])
        let end = try XCTUnwrap(actions[5]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(otherwise["WFControlFlowMode"] as? Int, 1)
        XCTAssertEqual(end["WFControlFlowMode"] as? Int, 2)
        XCTAssertEqual(otherwise["GroupingIdentifier"] as? String, start["GroupingIdentifier"] as? String)
        XCTAssertEqual(end["GroupingIdentifier"] as? String, start["GroupingIdentifier"] as? String)
        let endUUID = try XCTUnwrap(end["UUID"] as? String)

        let show = try XCTUnwrap(actions[6]["WFWorkflowActionParameters"] as? [String: Any])
        let showText = try XCTUnwrap(show["Text"] as? [String: Any])
        let showValue = try XCTUnwrap(showText["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(showValue["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["OutputName"] as? String, "If Result")
        XCTAssertEqual(attachment["OutputUUID"] as? String, endUUID)
    }

    func testAndAndOrPlaceRemainingOperandInShortCircuitBranch() throws {
        for operation in ["and", "or"] {
            let result = try LongwayCompiler().compile("""
            (shortcut "Boolean"
              (show-result (\(operation) #t (not #f))))
            """)
            let propertyList = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
            )
            let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
            let conditionalParameters = actions.enumerated().compactMap { index, action -> (Int, [String: Any])? in
                guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.conditional",
                      let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
                else { return nil }
                return (index, parameters)
            }
            let outerGroup = try XCTUnwrap(conditionalParameters.first?.1["GroupingIdentifier"] as? String)
            let outerStart = try XCTUnwrap(conditionalParameters.first { $0.1["GroupingIdentifier"] as? String == outerGroup && $0.1["WFControlFlowMode"] as? Int == 0 }?.0)
            let outerOtherwise = try XCTUnwrap(conditionalParameters.first { $0.1["GroupingIdentifier"] as? String == outerGroup && $0.1["WFControlFlowMode"] as? Int == 1 }?.0)
            let nestedStart = try XCTUnwrap(conditionalParameters.first { $0.1["GroupingIdentifier"] as? String != outerGroup && $0.1["WFControlFlowMode"] as? Int == 0 }?.0)

            if operation == "and" {
                XCTAssertTrue(outerStart < nestedStart && nestedStart < outerOtherwise)
                XCTAssertEqual(textLiteral(in: actions[outerOtherwise + 1]), "#f")
            } else {
                XCTAssertTrue(outerOtherwise < nestedStart)
                XCTAssertEqual(textLiteral(in: actions[outerStart + 1]), "#t")
            }
        }
    }

    func testLogicalOperatorsValidateTypesAndArity() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (show-result (and #t 1)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "and expects boolean operands")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (show-result (or #t)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "or expects at least 2 operands, got 1")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (show-result (not #t #f)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "not expects 1 operand, got 2")
        }
    }

    func testMathExpressionLowersToNumberCalculateAndShowResult() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Math"
          (show-result (+ 7 5)))
        """)

        XCTAssertEqual(result.actionCount, 3)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.number",
            "is.workflow.actions.math",
            "is.workflow.actions.showresult"
        ])

        let numberParameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(numberParameters["WFNumberActionNumber"] as? Double, 7)
        let numberUUID = try XCTUnwrap(numberParameters["UUID"] as? String)

        let mathParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(mathParameters["WFMathOperation"] as? String, "+")
        XCTAssertEqual(mathParameters["WFMathOperand"] as? Double, 5)
        let input = try XCTUnwrap(mathParameters["WFInput"] as? [String: Any])
        XCTAssertEqual(input["WFSerializationType"] as? String, "WFTextTokenAttachment")
        let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
        XCTAssertEqual(inputValue["OutputUUID"] as? String, numberUUID)
        XCTAssertEqual(inputValue["OutputName"] as? String, "Number")
        let calculationUUID = try XCTUnwrap(mathParameters["UUID"] as? String)

        let showParameters = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        let showText = try XCTUnwrap(showParameters["Text"] as? [String: Any])
        let showValue = try XCTUnwrap(showText["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(showValue["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["OutputUUID"] as? String, calculationUUID)
        XCTAssertEqual(attachment["OutputName"] as? String, "Calculation Result")
    }

    func testMathOperatorsUseShortcutOperationSymbols() throws {
        for (sourceOperator, shortcutOperator) in [("+", "+"), ("-", "-"), ("*", "×"), ("/", "÷")] {
            let result = try LongwayCompiler().compile("""
            (shortcut "Math"
              (show-result (\(sourceOperator) 8 2)))
            """)
            let propertyList = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
            )
            let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
            let parameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
            XCTAssertEqual(parameters["WFMathOperation"] as? String, shortcutOperator)
        }
    }

    func testVariadicMathChainsResultsLeftToRight() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Math"
          (show-result (- 20 3 2)))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(result.actionCount, 4)

        let firstMath = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let firstMathUUID = try XCTUnwrap(firstMath["UUID"] as? String)
        let secondMath = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        let secondInput = try XCTUnwrap(secondMath["WFInput"] as? [String: Any])
        let secondInputValue = try XCTUnwrap(secondInput["Value"] as? [String: Any])
        XCTAssertEqual(secondInputValue["OutputUUID"] as? String, firstMathUUID)
        XCTAssertEqual(secondMath["WFMathOperand"] as? Double, 2)
    }

    func testNumericLetBindingsAndNestedMathUseActionOutputs() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Math"
          (let ((x 10) (y 4))
            (show-result (* (+ x y) 2))))
        """)

        XCTAssertEqual(result.actionCount, 5)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.number",
            "is.workflow.actions.number",
            "is.workflow.actions.math",
            "is.workflow.actions.math",
            "is.workflow.actions.showresult"
        ])

        let yParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let yUUID = try XCTUnwrap(yParameters["UUID"] as? String)
        let addition = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        let operand = try XCTUnwrap(addition["WFMathOperand"] as? [String: Any])
        let operandValue = try XCTUnwrap(operand["Value"] as? [String: Any])
        XCTAssertEqual(operandValue["OutputUUID"] as? String, yUUID)
    }

    func testMathRejectsTextOperandsAndTooFewOperands() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (show-result (+ "one" 2)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "+ expects number operands")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Broken"
          (show-result (* 2)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "* expects at least 2 operands, got 1")
        }
    }

    func testShowResultEmbedsNumberLiteralDirectly() throws {
        let result = try LongwayCompiler().compile("""
        (shortcut "Number"
          (show-result 42))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let text = try XCTUnwrap(parameters["Text"] as? [String: Any])
        let value = try XCTUnwrap(text["Value"] as? [String: Any])
        XCTAssertEqual(value["string"] as? String, "42")
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

    private func textLiteral(in action: [String: Any]) -> String? {
        let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
        let text = parameters?["WFTextActionText"] as? [String: Any]
        let value = text?["Value"] as? [String: Any]
        return value?["string"] as? String
    }
}
