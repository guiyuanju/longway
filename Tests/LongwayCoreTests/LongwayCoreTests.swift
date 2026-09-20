import Foundation
import XCTest
@testable import LongwayCore

final class LongwayCoreTests: XCTestCase {
    func testProgramCompilesEachDefinitionIntoStandaloneShortcut() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (add x y)
          (+ x y))

        (define (main)
          (add 20 22))
        """)

        XCTAssertEqual(program.shortcuts.map(\.name), ["add", "main"])
        let addPropertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: program.shortcuts[0].data,
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(addPropertyList["WFWorkflowHasShortcutInputVariables"] as? Bool, true)
        XCTAssertEqual(
            addPropertyList["WFWorkflowInputContentItemClasses"] as? [String],
            ["WFDictionaryContentItem"]
        )
        XCTAssertEqual(
            addPropertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFNumberContentItem"]
        )

        let mainPropertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: program.shortcuts[1].data,
                format: nil
            ) as? [String: Any]
        )
        let actions = try XCTUnwrap(mainPropertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.dictionary",
            "is.workflow.actions.runworkflow",
            "is.workflow.actions.output"
        ])
        let dictionaryParameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let dictionaryUUID = try XCTUnwrap(dictionaryParameters["UUID"] as? String)
        let fields = try XCTUnwrap(dictionaryParameters["WFItems"] as? [String: Any])
        let fieldValue = try XCTUnwrap(fields["Value"] as? [String: Any])
        let items = try XCTUnwrap(fieldValue["WFDictionaryFieldValueItems"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { textTokenLiteral($0["WFKey"]) }, ["x", "y"])

        let runParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(runParameters["WFWorkflowName"] as? String, "add")
        let runInput = try XCTUnwrap(runParameters["WFInput"] as? [String: Any])
        let runInputValue = try XCTUnwrap(runInput["Value"] as? [String: Any])
        XCTAssertEqual(runInputValue["OutputUUID"] as? String, dictionaryUUID)
    }

    func testFunctionCallsValidateTargetArityAndSingleResultAPI() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (main) (missing 1))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "unknown value form 'missing'")
        }
        XCTAssertThrowsError(try LongwayCompiler().compileProgram("""
        (define (identity value) value)
        (define (main) (identity 1 2))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "identity expects 1 argument, got 2")
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (one) "one")
        (define (two) "two")
        """)) { error in
            XCTAssertEqual(
                (error as? LongwayError)?.message,
                "source defines 2 functions; use compileProgram to compile all functions"
            )
        }
    }

    func testFunctionParametersReadNamedValuesFromShortcutInput() throws {
        let result = try LongwayCompiler().compile("""
        (define (add x y)
          (+ x y))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])

        for (index, name) in ["x", "y"].enumerated() {
            XCTAssertEqual(
                actions[index]["WFWorkflowActionIdentifier"] as? String,
                "is.workflow.actions.getvalueforkey"
            )
            let parameters = try XCTUnwrap(actions[index]["WFWorkflowActionParameters"] as? [String: Any])
            XCTAssertEqual(parameters["CustomOutputName"] as? String, name)
            XCTAssertEqual(parameters["WFDictionaryKey"] as? String, name)
            XCTAssertEqual(parameters["WFGetDictionaryValueType"] as? String, "Value")
            let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
            let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
            XCTAssertEqual(inputValue["Type"] as? String, "ExtensionInput")
        }
        XCTAssertEqual(actions.last?["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.output")
    }

    func testSelfTailRecursiveFunctionCompilesToABoundedLoopNotRunWorkflow() throws {
        let result = try LongwayCompiler().compile("""
        (define (sum-to n acc)
          (if (= n 0)
              acc
              (sum-to (- n 1) (+ acc n))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            propertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFNumberContentItem"]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let identifiers = actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String }
        XCTAssertFalse(identifiers.contains("is.workflow.actions.runworkflow"))
        XCTAssertFalse(identifiers.contains("is.workflow.actions.dictionary"))

        let repeatStart = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.repeat.count"
        })
        let repeatParameters = try XCTUnwrap(repeatStart["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(repeatParameters["WFRepeatCount"] as? Int, tailCallLoopLimit)

        let setVariableNames = actions.compactMap { action -> String? in
            guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.setvariable",
                  let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
            else { return nil }
            return parameters["WFVariableName"] as? String
        }
        XCTAssertTrue(setVariableNames.contains("n"))
        XCTAssertTrue(setVariableNames.contains("acc"))
        XCTAssertTrue(setVariableNames.contains("#result"))
    }

    func testBaseCaseStopsAndOutputsInsteadOfIdlingToTheLoopBound() throws {
        let result = try LongwayCompiler().compile("""
        (define (sum-to n acc)
          (if (= n 0)
              acc
              (sum-to (- n 1) (+ acc n))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let identifiers = actions.map { $0["WFWorkflowActionIdentifier"] as? String }

        let resultAssignmentIndex = try XCTUnwrap(actions.firstIndex {
            guard $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.setvariable",
                  let parameters = $0["WFWorkflowActionParameters"] as? [String: Any]
            else { return false }
            return parameters["WFVariableName"] as? String == "#result"
        })
        // The base case must Stop and Output right after recording its value, before
        // the Otherwise branch (WFControlFlowMode 1) that starts the recursive step.
        // A bare is.workflow.actions.exit would halt the workflow with no output.
        let inlineOutputIndex = resultAssignmentIndex + 1
        XCTAssertEqual(identifiers[inlineOutputIndex], "is.workflow.actions.output")
        XCTAssertFalse(identifiers.contains("is.workflow.actions.exit"))

        let inlineOutput = try XCTUnwrap(actions[inlineOutputIndex]["WFWorkflowActionParameters"] as? [String: Any])
        let wfOutput = try XCTUnwrap(inlineOutput["WFOutput"] as? [String: Any])
        let value = try XCTUnwrap(wfOutput["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(value["attachmentsByRange"] as? [String: Any])
        XCTAssertFalse(attachments.isEmpty, "base case must output its computed value, not an empty result")

        // The post-loop read stays as the fail-safe for recursion that never
        // reaches a base case, so there are exactly two output actions.
        XCTAssertEqual(identifiers.filter { $0 == "is.workflow.actions.output" }.count, 2)
    }

    func testLoopVariableReadsAreMaterializedBeforeUseInAConditional() throws {
        // A named-variable Get Variable read is runtime-generic to the Shortcuts
        // editor, exactly like dictionary extraction: skip materializing it and the
        // editor can't infer the condition's input type, rendering "is anything"
        // instead of "is 0" even though the comparison still targets the right value.
        let result = try LongwayCompiler().compile("""
        (define (sum-to n acc)
          (if (= n 0)
              acc
              (sum-to (- n 1) (+ acc n))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])

        let comparison = try XCTUnwrap(actions.first {
            guard $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.conditional",
                  let parameters = $0["WFWorkflowActionParameters"] as? [String: Any]
            else { return false }
            return parameters["WFNumberValue"] as? Int == 0
        })
        let parameters = try XCTUnwrap(comparison["WFWorkflowActionParameters"] as? [String: Any])
        let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
        let variable = try XCTUnwrap(input["Variable"] as? [String: Any])
        let attachment = try XCTUnwrap(variable["Value"] as? [String: Any])
        XCTAssertEqual(attachment["OutputName"] as? String, "Number")

        let attachmentUUID = try XCTUnwrap(attachment["OutputUUID"] as? String)
        let producer = try XCTUnwrap(actions.first {
            ($0["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String == attachmentUUID
        })
        XCTAssertEqual(producer["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.number")
    }

    func testNonTailSelfRecursionStillCallsItsStandaloneShortcut() throws {
        let result = try LongwayCompiler().compile("""
        (define (count-up n)
          (if (= n 0)
              0
              (+ 1 (count-up (- n 1)))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let recursiveRun = try XCTUnwrap(actions.first { action in
            guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.runworkflow",
                  let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
            else { return false }
            return parameters["WFWorkflowName"] as? String == "count-up"
        })
        let runParameters = try XCTUnwrap(recursiveRun["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(runParameters["CustomOutputName"] as? String, "count-up Result")
    }

    func testTailRecursionWithShowResultFallsBackToRunWorkflow() throws {
        // show-result may only appear as a function's (or let's) literal tail form,
        // never nested inside an if branch, so this is the only way a self-tail-call
        // can coexist with show-result at all.
        let result = try LongwayCompiler().compile("""
        (define (count-down n)
          (show-result (count-down (- n 1))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertTrue(actions.contains { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.runworkflow" })
        XCTAssertFalse(actions.contains { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.repeat.count" })
    }

    func testTailRecursionWithLeadingSideEffectFallsBackToRunWorkflow() throws {
        let result = try LongwayCompiler().compile("""
        (define (count-down n)
          (notification "tick")
          (if (= n 0)
              0
              (count-down (- n 1))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertTrue(actions.contains { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.runworkflow" })
        XCTAssertFalse(actions.contains { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.repeat.count" })
    }

    func testMutuallyRecursiveFunctionsCompile() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (even n)
          (if (= n 0) #t (odd (- n 1))))

        (define (odd n)
          (if (= n 0) #f (even (- n 1))))
        """)

        XCTAssertEqual(program.shortcuts.map(\.name), ["even", "odd"])
        for (shortcut, target) in zip(program.shortcuts, ["odd", "even"]) {
            let propertyList = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: shortcut.data, format: nil) as? [String: Any]
            )
            let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
            XCTAssertTrue(actions.contains { action in
                guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.runworkflow",
                      let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
                else { return false }
                return parameters["WFWorkflowName"] as? String == target
            })
        }
    }

    func testUnconstrainedFunctionRemainsGenericAcrossCallTypes() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (identity value) value)
        (define (number-main) (+ (identity 1) 2))
        (define (text-main) (identity "hello"))
        """)

        let identity = try XCTUnwrap(program.shortcuts.first { $0.name == "identity" })
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: identity.data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            propertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFStringContentItem", "WFNumberContentItem", "WFGenericFileContentItem"]
        )
    }

    func testInferredFunctionTypesRejectKnownBadCalls() throws {
        XCTAssertThrowsError(try LongwayCompiler().compileProgram("""
        (define (double value) (+ value value))
        (define (main) (double "wrong"))
        """)) { error in
            XCTAssertEqual(
                (error as? LongwayError)?.message,
                "double argument 1 has incompatible type"
            )
        }
    }

    func testDefinitionsValidateNamesAndLegacyShortcutSyntax() throws {
        XCTAssertThrowsError(try LongwayCompiler().compileProgram("")) { error in
            XCTAssertEqual(
                (error as? LongwayError)?.message,
                "expected at least one function definition"
            )
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (shortcut "Legacy" (show-result "no"))
        """)) { error in
            XCTAssertEqual(
                (error as? LongwayError)?.message,
                "top-level forms must be function definitions"
            )
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (same value value) value)
        """)) { error in
            XCTAssertEqual(
                (error as? LongwayError)?.message,
                "duplicate function parameter 'value'"
            )
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (+ value) value)
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "function name '+' is reserved")
        }
        XCTAssertThrowsError(try LongwayCompiler().compileProgram("""
        (define (helper) "one")
        (define (Helper) "two")
        """)) { error in
            XCTAssertEqual(
                (error as? LongwayError)?.message,
                "function name 'Helper' conflicts with 'helper' on case-insensitive file systems"
            )
        }
    }

    func testShowResultEmbedsStringLiteralDirectly() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (show-result "Hello from Longway!"))
        """)

        XCTAssertEqual(result.name, "test")
        XCTAssertEqual(result.actionCount, 2)

        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 2)
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
        (define (test)
          (let ((content "Hello from Longway!"))
            (show-result content)))
        """)

        XCTAssertEqual(result.actionCount, 3)
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
        (define (test)
          (show-result #t))
        """)

        XCTAssertEqual(result.actionCount, 2)
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
        (define (test)
          (let ((enabled #t))
            (show-result enabled)))
        """)

        XCTAssertEqual(result.actionCount, 3)
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
        (define (test)
          (show-result (not #t)))
        """)

        XCTAssertEqual(result.actionCount, 8)
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
            "is.workflow.actions.showresult",
            "is.workflow.actions.output"
        ])

        let inputText = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let inputUUID = try XCTUnwrap(inputText["UUID"] as? String)
        let start = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(start["WFControlFlowMode"] as? Int, 0)
        XCTAssertEqual(start["WFCondition"] as? Int, 4)
        XCTAssertEqual(start["WFConditionalActionString"] as? String, "#t")
        let input = try XCTUnwrap(start["WFInput"] as? [String: Any])
        XCTAssertEqual(input["Type"] as? String, "Variable")
        let variable = try XCTUnwrap(input["Variable"] as? [String: Any])
        XCTAssertEqual(variable["WFSerializationType"] as? String, "WFTextTokenAttachment")
        let inputValue = try XCTUnwrap(variable["Value"] as? [String: Any])
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
            (define (test)
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
        (define (test)
          (show-result (and #t 1)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "and expects boolean operands")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (or #t)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "or expects at least 2 operands, got 1")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (not #t #f)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "not expects 1 operand, got 2")
        }
    }

    func testIfValueLowersToTypedShortcutResult() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (show-result (if #t "yes" "no")))
        """)

        XCTAssertEqual(result.actionCount, 8)
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
            "is.workflow.actions.showresult",
            "is.workflow.actions.output"
        ])
        XCTAssertEqual(textLiteral(in: actions[2]), "yes")
        XCTAssertEqual(textLiteral(in: actions[4]), "no")

        let endParameters = try XCTUnwrap(actions[5]["WFWorkflowActionParameters"] as? [String: Any])
        let endUUID = try XCTUnwrap(endParameters["UUID"] as? String)
        let showParameters = try XCTUnwrap(actions[6]["WFWorkflowActionParameters"] as? [String: Any])
        let showText = try XCTUnwrap(showParameters["Text"] as? [String: Any])
        let showValue = try XCTUnwrap(showText["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(showValue["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["OutputName"] as? String, "If Result")
        XCTAssertEqual(attachment["OutputUUID"] as? String, endUUID)
    }

    func testIfNumberResultCanFeedArithmetic() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (let ((x 10) (y 20))
            (show-result (+ (if #t x y) 5))))
        """)

        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let xParameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let yParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let xUUID = try XCTUnwrap(xParameters["UUID"] as? String)
        let yUUID = try XCTUnwrap(yParameters["UUID"] as? String)

        for (index, expectedUUID) in [(4, xUUID), (6, yUUID)] {
            XCTAssertEqual(actions[index]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.number")
            let parameters = try XCTUnwrap(actions[index]["WFWorkflowActionParameters"] as? [String: Any])
            let number = try XCTUnwrap(parameters["WFNumberActionNumber"] as? [String: Any])
            let numberValue = try XCTUnwrap(number["Value"] as? [String: Any])
            XCTAssertEqual(numberValue["OutputUUID"] as? String, expectedUUID)
        }

        let endParameters = try XCTUnwrap(actions[7]["WFWorkflowActionParameters"] as? [String: Any])
        let endUUID = try XCTUnwrap(endParameters["UUID"] as? String)
        let mathParameters = try XCTUnwrap(actions[8]["WFWorkflowActionParameters"] as? [String: Any])
        let mathInput = try XCTUnwrap(mathParameters["WFInput"] as? [String: Any])
        let mathInputValue = try XCTUnwrap(mathInput["Value"] as? [String: Any])
        XCTAssertEqual(mathInputValue["OutputName"] as? String, "If Result")
        XCTAssertEqual(mathInputValue["OutputUUID"] as? String, endUUID)
    }

    func testIfFormPlacesActionsInsideBranches() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (if #t
              (show-result "yes")
              (show-result "no"))
          #t)
        """)

        XCTAssertEqual(result.actionCount, 7)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.gettext",
            "is.workflow.actions.conditional",
            "is.workflow.actions.showresult",
            "is.workflow.actions.conditional",
            "is.workflow.actions.showresult",
            "is.workflow.actions.conditional",
            "is.workflow.actions.output"
        ])
        let startParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let input = try XCTUnwrap(startParameters["WFInput"] as? [String: Any])
        XCTAssertEqual(input["Type"] as? String, "Variable")
        XCTAssertNotNil(input["Variable"] as? [String: Any])

        let trueParameters = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        let falseParameters = try XCTUnwrap(actions[4]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(textTokenLiteral(trueParameters["Text"]), "yes")
        XCTAssertEqual(textTokenLiteral(falseParameters["Text"]), "no")
    }

    func testIfValidatesArityConditionAndBranchTypes() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (if #t "yes")))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "if expects 3 arguments, got 2")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (if 1 "yes" "no")))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "if expects a boolean condition")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (if #t "yes" 0)))
        """)) { error in
            XCTAssertEqual(
                (error as? LongwayError)?.message,
                "if branches must have matching types"
            )
        }
    }

    func testNumericEqualityUsesDirectIsConditionWithTypedInputAndLiteralZero() throws {
        let result = try LongwayCompiler().compile("""
        (define (test n)
          (= n 0))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let comparisons = actions.filter { action in
            guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.conditional",
                  let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
            else { return false }
            return parameters["WFControlFlowMode"] as? Int == 0
        }
        let comparison = try XCTUnwrap(comparisons.first)
        XCTAssertEqual(comparisons.count, 1)

        let parameters = try XCTUnwrap(comparison["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(parameters["WFCondition"] as? Int, 4)
        XCTAssertEqual(parameters["WFNumberValue"] as? Double, 0)
        XCTAssertNil(parameters["WFConditionalActionString"])

        let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
        let inputVariable = try XCTUnwrap(input["Variable"] as? [String: Any])
        let inputValue = try XCTUnwrap(inputVariable["Value"] as? [String: Any])
        let inputUUID = try XCTUnwrap(inputValue["OutputUUID"] as? String)
        let inputProducer = try XCTUnwrap(actions.first { action in
            (action["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String == inputUUID
        })
        XCTAssertEqual(
            inputProducer["WFWorkflowActionIdentifier"] as? String,
            "is.workflow.actions.number"
        )
    }

    func testEqualityAgainstAVariableSubtractsAndTestsAgainstLiteralZero() throws {
        // Shortcuts' `is` condition on a Number input has no variable slot: the
        // editor only accepts a typed number, so WFConditionalActionString is
        // never read and the condition silently never matches. Comparing the
        // difference against a literal zero is the shape that does work.
        let result = try LongwayCompiler().compile("""
        (define (same a b)
          (= a b))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])

        let comparison = try XCTUnwrap(actions.first {
            guard $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.conditional",
                  let parameters = $0["WFWorkflowActionParameters"] as? [String: Any]
            else { return false }
            return parameters["WFControlFlowMode"] as? Int == 0
        })
        let parameters = try XCTUnwrap(comparison["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(parameters["WFCondition"] as? Int, 4)
        XCTAssertEqual(parameters["WFNumberValue"] as? Double, 0)
        XCTAssertNil(parameters["WFConditionalActionString"])

        let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
        let variable = try XCTUnwrap(input["Variable"] as? [String: Any])
        let inputValue = try XCTUnwrap(variable["Value"] as? [String: Any])
        let inputUUID = try XCTUnwrap(inputValue["OutputUUID"] as? String)

        let math = try XCTUnwrap(actions.first {
            ($0["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String == inputUUID
        })
        XCTAssertEqual(math["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.math")
        let mathParameters = try XCTUnwrap(math["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(mathParameters["WFMathOperation"] as? String, "-")

        // Both operands reach the subtraction: a as the input, b as the operand.
        let operand = try XCTUnwrap(mathParameters["WFMathOperand"] as? [String: Any])
        let operandValue = try XCTUnwrap(operand["Value"] as? [String: Any])
        XCTAssertEqual(operandValue["Type"] as? String, "ActionOutput")
        let mathInput = try XCTUnwrap(mathParameters["WFInput"] as? [String: Any])
        let mathInputValue = try XCTUnwrap(mathInput["Value"] as? [String: Any])
        XCTAssertEqual(mathInputValue["Type"] as? String, "ActionOutput")
        XCTAssertNotEqual(
            mathInputValue["OutputUUID"] as? String,
            operandValue["OutputUUID"] as? String
        )
    }

    func testNumericComparisonLowersToShortcutCondition() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (show-result (> 7 5)))
        """)

        XCTAssertEqual(result.actionCount, 8)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let number = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let numberUUID = try XCTUnwrap(number["UUID"] as? String)
        let comparison = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(comparison["WFCondition"] as? Int, 2)
        XCTAssertEqual(comparison["WFNumberValue"] as? Double, 5)

        let input = try XCTUnwrap(comparison["WFInput"] as? [String: Any])
        XCTAssertEqual(input["Type"] as? String, "Variable")
        let variable = try XCTUnwrap(input["Variable"] as? [String: Any])
        let value = try XCTUnwrap(variable["Value"] as? [String: Any])
        XCTAssertEqual(value["OutputUUID"] as? String, numberUUID)
        XCTAssertEqual(value["OutputName"] as? String, "Number")
    }

    func testComparisonOperatorsUseShortcutConditionCodes() throws {
        for (sourceOperator, shortcutCondition) in [("<", 0), ("<=", 1), (">", 2), (">=", 3)] {
            let result = try LongwayCompiler().compile("""
            (define (test)
              (show-result (\(sourceOperator) 8 2)))
            """)
            let propertyList = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
            )
            let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
            let parameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
            XCTAssertEqual(parameters["WFCondition"] as? Int, shortcutCondition)
        }
    }

    func testComparisonReferencesVariableOperandAndChainsPairs() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (let ((x 1) (y 2))
            (show-result (< x y 3))))
        """)

        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let xUUID = try XCTUnwrap((actions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String)
        let yUUID = try XCTUnwrap((actions[1]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String)

        // x < y compares x - y against zero, because a number condition has no
        // variable slot; y < 3 keeps the literal in the number field.
        let difference = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(actions[2]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.math")
        XCTAssertEqual(difference["WFMathOperation"] as? String, "-")
        let differenceInput = try XCTUnwrap(difference["WFInput"] as? [String: Any])
        XCTAssertEqual((differenceInput["Value"] as? [String: Any])?["OutputUUID"] as? String, xUUID)
        let differenceOperand = try XCTUnwrap(difference["WFMathOperand"] as? [String: Any])
        XCTAssertEqual((differenceOperand["Value"] as? [String: Any])?["OutputUUID"] as? String, yUUID)
        let differenceUUID = try XCTUnwrap(difference["UUID"] as? String)

        let outer = try XCTUnwrap(actions[3]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(outer["WFCondition"] as? Int, 0)
        XCTAssertEqual(outer["WFNumberValue"] as? Double, 0)
        XCTAssertNil(outer["WFConditionalActionString"])
        let outerInput = try XCTUnwrap(outer["WFInput"] as? [String: Any])
        let outerVariable = try XCTUnwrap(outerInput["Variable"] as? [String: Any])
        let outerValue = try XCTUnwrap(outerVariable["Value"] as? [String: Any])
        XCTAssertEqual(outerValue["OutputUUID"] as? String, differenceUUID)

        let inner = try XCTUnwrap(actions[4]["WFWorkflowActionParameters"] as? [String: Any])
        let innerInput = try XCTUnwrap(inner["WFInput"] as? [String: Any])
        let innerVariable = try XCTUnwrap(innerInput["Variable"] as? [String: Any])
        let innerValue = try XCTUnwrap(innerVariable["Value"] as? [String: Any])
        XCTAssertEqual(innerValue["OutputUUID"] as? String, yUUID)
        XCTAssertEqual(inner["WFNumberValue"] as? Double, 3)
    }

    func testNumericEqualityUsesShortcutIsCondition() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (show-result (= 4 4)))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let startConditions = try actions.compactMap { action -> Int? in
            guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.conditional",
                  let parameters = action["WFWorkflowActionParameters"] as? [String: Any],
                  parameters["WFControlFlowMode"] as? Int == 0
            else { return nil }
            return try XCTUnwrap(parameters["WFCondition"] as? Int)
        }
        XCTAssertEqual(startConditions, [4])
    }

    func testComparisonsValidateTypesAndArity() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (< 1)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "< expects at least 2 operands, got 1")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (>= 1 "two")))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, ">= expects number operands")
        }
    }

    func testMathExpressionLowersToNumberCalculateAndShowResult() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (show-result (+ 7 5)))
        """)

        XCTAssertEqual(result.actionCount, 4)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.number",
            "is.workflow.actions.math",
            "is.workflow.actions.showresult",
            "is.workflow.actions.output"
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
            (define (test)
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
        (define (test)
          (show-result (- 20 3 2)))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(result.actionCount, 5)

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
        (define (test)
          (let ((x 10) (y 4))
            (show-result (* (+ x y) 2))))
        """)

        XCTAssertEqual(result.actionCount, 6)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.number",
            "is.workflow.actions.number",
            "is.workflow.actions.math",
            "is.workflow.actions.math",
            "is.workflow.actions.showresult",
            "is.workflow.actions.output"
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
        (define (test)
          (show-result (+ "one" 2)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "+ expects number operands")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (* 2)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "* expects at least 2 operands, got 1")
        }
    }

    func testShowResultEmbedsNumberLiteralDirectly() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
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
        (define (test)
          (open-url "https://example.com")
          "done")
        """)

        XCTAssertEqual(result.actionCount, 3)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.url")
        XCTAssertEqual(actions[1]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.openurl")
    }

    func testLetRejectsUnknownVariable() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result missing))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "unknown variable 'missing'")
        }
    }

    func testLetRejectsDuplicateBindings() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (let ((content "one") (content "two"))
            (show-result content)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "duplicate let binding 'content'")
        }
    }

    func testLetInitializersUseOuterScope() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (let ((first "one") (second first))
            (show-result second)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "unknown variable 'first'")
        }
    }

    func testShowResultRequiresOneArgument() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "show-result expects 1 argument, got 0")
        }
    }

    func testReportsSourceLocationForUnknownAction() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (teleport "home")
          "done")
        """)) { error in
            guard let error = error as? LongwayError else {
                return XCTFail("Expected LongwayError, got \(error)")
            }
            XCTAssertEqual(error.location, SourceLocation(line: 2, column: 4))
            XCTAssertEqual(error.message, "unknown action 'teleport'")
        }
    }

    func testRejectsTrailingTopLevelExpression() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("(define (one) \"1\") (text \"2\")")) { error in
            XCTAssertTrue(String(describing: error).contains("top-level forms must be function definitions"))
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
        return textTokenLiteral(parameters?["WFTextActionText"])
    }

    private func textTokenLiteral(_ token: Any?) -> String? {
        let text = token as? [String: Any]
        let value = text?["Value"] as? [String: Any]
        return value?["string"] as? String
    }
}
