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

    func testTailRecursionWithInteractiveInitializerFallsBackToRunWorkflow() throws {
        let result = try LongwayCompiler().compile("""
        (define (retry n)
          (if (= n 0)
              "done"
              (let ((answer (ask-text "Continue?")))
                (retry (- n 1)))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let identifiers = actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String }
        XCTAssertTrue(identifiers.contains("is.workflow.actions.ask"))
        XCTAssertTrue(identifiers.contains("is.workflow.actions.runworkflow"))
        XCTAssertFalse(identifiers.contains("is.workflow.actions.repeat.count"))
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
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (let*) "no")
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "function name 'let*' is reserved")
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
            XCTAssertEqual((error as? LongwayError)?.message, "or expects at least 2 arguments, got 1")
        }

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (test)
          (show-result (not #t #f)))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "not expects 1 argument, got 2")
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
            XCTAssertEqual((error as? LongwayError)?.message, "< expects at least 2 arguments, got 1")
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
            XCTAssertEqual((error as? LongwayError)?.message, "* expects at least 2 arguments, got 1")
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

    func testLetStarInitializersSeeEarlierBindings() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (let* ((x 10)
                 (y (+ x 5)))
            y))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.number",
            "is.workflow.actions.math",
            "is.workflow.actions.output"
        ])

        let xUUID = try XCTUnwrap(
            (actions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )
        let math = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let input = try XCTUnwrap(math["WFInput"] as? [String: Any])
        let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
        XCTAssertEqual(inputValue["OutputUUID"] as? String, xUUID)
    }

    func testLetStarCanWrapActionForms() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (let* ((greeting "Hello")
                 (message (string-append greeting "!")))
            (show-result message))
          "done")
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertTrue(actions.contains {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.showresult"
        })
    }

    func testLetStarBindingsCanSequentiallyShadow() throws {
        let result = try LongwayCompiler().compile("""
        (define (test)
          (let* ((x 10)
                 (x (+ x 1)))
            x))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let numberUUID = try XCTUnwrap(
            (actions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )
        let mathParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        let mathInput = try XCTUnwrap(mathParameters["WFInput"] as? [String: Any])
        let mathInputValue = try XCTUnwrap(mathInput["Value"] as? [String: Any])
        XCTAssertEqual(mathInputValue["OutputUUID"] as? String, numberUUID)

        let mathUUID = try XCTUnwrap(mathParameters["UUID"] as? String)
        let outputParameters = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        let output = try XCTUnwrap(outputParameters["WFOutput"] as? [String: Any])
        let outputValue = try XCTUnwrap(output["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(outputValue["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["OutputUUID"] as? String, mathUUID)
    }

    func testLetStarPreservesTailCallOptimization() throws {
        let result = try LongwayCompiler().compile("""
        (define (count-down n)
          (let* ((next (- n 1)))
            (if (= n 0)
                0
                (count-down next))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let identifiers = actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String }
        XCTAssertTrue(identifiers.contains("is.workflow.actions.repeat.count"))
        XCTAssertFalse(identifiers.contains("is.workflow.actions.runworkflow"))
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

    func testListLiteralLowersToAListActionWithTypedItems() throws {
        let result = try LongwayCompiler().compile("""
        (define (names)
          (list "Ada" 42 #t))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.list",
            "is.workflow.actions.output"
        ])

        // WFItems is a content array: Apple's own shortcuts store a literal item as
        // a plain string. Wrapping items in WFItemType/WFValue pairs, as a Dictionary
        // action's fields are, makes Shortcuts read the whole array as one item.
        let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let items = try XCTUnwrap(parameters["WFItems"] as? [Any])
        XCTAssertEqual(items as? [String], ["Ada", "42", "#t"])

        // A list has no dedicated Shortcut content class, so it exports the
        // generic set rather than claiming to be text or a number.
        XCTAssertEqual(
            propertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFStringContentItem", "WFNumberContentItem", "WFGenericFileContentItem"]
        )
    }

    func testListItemReferencingAnotherActionKeepsItsAttachment() throws {
        let result = try LongwayCompiler().compile("""
        (define (pair x)
          (list x "fixed"))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let list = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.list"
        })
        let parameters = try XCTUnwrap(list["WFWorkflowActionParameters"] as? [String: Any])
        let items = try XCTUnwrap(parameters["WFItems"] as? [Any])
        XCTAssertEqual(items.count, 2)

        let reference = try XCTUnwrap(items.first as? [String: Any])
        XCTAssertEqual(reference["WFSerializationType"] as? String, "WFTextTokenString")
        let value = try XCTUnwrap(reference["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(value["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["OutputName"] as? String, "x")
        XCTAssertEqual(items.last as? String, "fixed")
    }

    func testListAccessorsLowerToShortcutListActions() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (head) (first (list 1 2)))
        (define (tail-item) (last (list 1 2)))
        (define (size) (length (list 1 2)))
        (define (second) (list-ref (list 1 2) 1))
        """)

        var specifiers: [String: String] = [:]
        for shortcut in program.shortcuts {
            let propertyList = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: shortcut.data, format: nil) as? [String: Any]
            )
            let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
            let listUUID = try XCTUnwrap(
                (actions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
            )
            let reader = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
            let inputKey = shortcut.name == "size" ? "Input" : "WFInput"
            let input = try XCTUnwrap(reader[inputKey] as? [String: Any])
            let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
            XCTAssertEqual(inputValue["OutputUUID"] as? String, listUUID)

            if shortcut.name == "size" {
                XCTAssertEqual(actions[1]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.count")
                XCTAssertEqual(reader["WFCountType"] as? String, "Items")
                XCTAssertNil(reader["WFInput"], "the Count action reads its input from Input, not WFInput")
                XCTAssertEqual(
                    propertyList["WFWorkflowOutputContentItemClasses"] as? [String],
                    ["WFNumberContentItem"]
                )
                continue
            }
            XCTAssertEqual(actions[1]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.getitemfromlist")
            specifiers[shortcut.name] = reader["WFItemSpecifier"] as? String
            if shortcut.name == "second" {
                // Longway indexes from 0 like Scheme's list-ref; Shortcuts indexes from 1.
                XCTAssertEqual(reader["WFItemIndex"] as? Int, 2)
            }
        }
        XCTAssertEqual(specifiers, [
            "head": "First Item",
            "tail-item": "Last Item",
            "second": "Item At Index"
        ])
    }

    func testComputedListIndexIsOffsetByAMathAction() throws {
        let result = try LongwayCompiler().compile("""
        (define (item-at items index)
          (list-ref items index))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])

        let reader = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.getitemfromlist"
        })
        let parameters = try XCTUnwrap(reader["WFWorkflowActionParameters"] as? [String: Any])
        let index = try XCTUnwrap(parameters["WFItemIndex"] as? [String: Any])
        let indexValue = try XCTUnwrap(index["Value"] as? [String: Any])
        let indexUUID = try XCTUnwrap(indexValue["OutputUUID"] as? String)

        let math = try XCTUnwrap(actions.first {
            ($0["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String == indexUUID
        })
        XCTAssertEqual(math["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.math")
        let mathParameters = try XCTUnwrap(math["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(mathParameters["WFMathOperation"] as? String, "+")
        XCTAssertEqual(mathParameters["WFMathOperand"] as? Int, 1)
    }

    func testEmptyComparesTheItemCountToZero() throws {
        let result = try LongwayCompiler().compile("""
        (define (none) (empty? (list 1)))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            propertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFStringContentItem"]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])

        let count = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.count"
        })
        let countUUID = try XCTUnwrap(
            (count["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )
        let condition = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.conditional"
        })
        let parameters = try XCTUnwrap(condition["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(parameters["WFCondition"] as? Int, 4)
        XCTAssertEqual(parameters["WFNumberValue"] as? Int, 0)
        let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
        let variable = try XCTUnwrap(input["Variable"] as? [String: Any])
        let attachment = try XCTUnwrap(variable["Value"] as? [String: Any])
        XCTAssertEqual(attachment["OutputUUID"] as? String, countUUID)
    }

    func testListsCrossLoopVariablesThroughGetVariableWithoutCoercion() throws {
        // Passing a list through Text or Number would flatten it, so a list written
        // to a tail-call loop variable goes through Get Variable instead.
        let result = try LongwayCompiler().compile("""
        (define (sum-list items index total)
          (if (= index (length items))
              total
              (sum-list items (+ index 1) (+ total (list-ref items index)))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let identifiers = actions.map { $0["WFWorkflowActionIdentifier"] as? String }
        XCTAssertTrue(identifiers.contains("is.workflow.actions.repeat.count"))

        let itemsWrites = actions.enumerated().filter { _, action in
            guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.setvariable",
                  let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
            else { return false }
            return parameters["WFVariableName"] as? String == "items"
        }
        XCTAssertEqual(itemsWrites.count, 2, "the list is seeded once and rewritten once per iteration")
        for (_, write) in itemsWrites {
            let parameters = try XCTUnwrap(write["WFWorkflowActionParameters"] as? [String: Any])
            let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
            let value = try XCTUnwrap(input["Value"] as? [String: Any])
            let sourceUUID = try XCTUnwrap(value["OutputUUID"] as? String)
            let producer = try XCTUnwrap(actions.first {
                ($0["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String == sourceUUID
            })
            XCTAssertEqual(producer["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.getvariable")
        }
    }

    func testListsInferParameterAndReturnTypesAcrossFunctions() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (size items) (length items))
        (define (main) (length (list 1 2 3)))
        """)
        XCTAssertEqual(program.shortcuts.map(\.name), ["size", "main"])

        let sizePropertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: program.shortcuts[0].data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            sizePropertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFNumberContentItem"]
        )

        XCTAssertThrowsError(try LongwayCompiler().compileProgram("""
        (define (size items) (length items))
        (define (main) (size 7))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "size argument 1 has incompatible type")
        }
    }

    func testListArgumentRidesInAnArrayTypedDictionaryField() throws {
        // A plain text field would flatten the list to newline-joined text, which
        // reads back as a single item. Shortcuts types an array field as
        // WFItemType 2 and wraps the variable in WFArraySubstitutableParameterState.
        let program = try LongwayCompiler().compileProgram("""
        (define (size items) (length items))
        (define (main) (size (list 1 2 3)))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: program.shortcuts[1].data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let list = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.list"
        })
        let listUUID = try XCTUnwrap(
            (list["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )

        let dictionary = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.dictionary"
        })
        let parameters = try XCTUnwrap(dictionary["WFWorkflowActionParameters"] as? [String: Any])
        let fields = try XCTUnwrap(parameters["WFItems"] as? [String: Any])
        let fieldValue = try XCTUnwrap(fields["Value"] as? [String: Any])
        let items = try XCTUnwrap(fieldValue["WFDictionaryFieldValueItems"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["WFItemType"] as? Int, 2)

        let value = try XCTUnwrap(item["WFValue"] as? [String: Any])
        XCTAssertEqual(value["WFSerializationType"] as? String, "WFArraySubstitutableParameterState")
        let attachment = try XCTUnwrap(value["Value"] as? [String: Any])
        XCTAssertEqual(attachment["WFSerializationType"] as? String, "WFTextTokenAttachment")
        let reference = try XCTUnwrap(attachment["Value"] as? [String: Any])
        XCTAssertEqual(reference["OutputUUID"] as? String, listUUID)
    }

    func testListResultReturnsAsASingleAttachmentTokenAndCanBeCalled() throws {
        // The Shortcuts editor writes a List variable into Stop and Output as one
        // attachment filling the whole token string, which is what every other
        // output here already uses, so a list result needs no special encoding.
        let program = try LongwayCompiler().compileProgram("""
        (define (make) (list 1 2 3))
        (define (main) (first (make)))
        """)
        let makePropertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: program.shortcuts[0].data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            makePropertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFStringContentItem", "WFNumberContentItem", "WFGenericFileContentItem"]
        )
        let makeActions = try XCTUnwrap(makePropertyList["WFWorkflowActions"] as? [[String: Any]])
        let listUUID = try XCTUnwrap(
            (makeActions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )
        let output = try XCTUnwrap(makeActions.last?["WFWorkflowActionParameters"] as? [String: Any])
        let outputValue = try XCTUnwrap(output["WFOutput"] as? [String: Any])
        XCTAssertEqual(outputValue["WFSerializationType"] as? String, "WFTextTokenString")
        let token = try XCTUnwrap(outputValue["Value"] as? [String: Any])
        XCTAssertEqual(token["string"] as? String, "\u{FFFC}")
        let attachments = try XCTUnwrap(token["attachmentsByRange"] as? [String: Any])
        let attachment = try XCTUnwrap(attachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(attachment["OutputUUID"] as? String, listUUID)

        // The caller reads that result straight into a list operation.
        let mainActions = try XCTUnwrap(
            (PropertyListSerialization.propertyList(from: program.shortcuts[1].data, format: nil) as? [String: Any])?["WFWorkflowActions"] as? [[String: Any]]
        )
        let run = try XCTUnwrap(mainActions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.runworkflow"
        })
        let runParameters = try XCTUnwrap(run["WFWorkflowActionParameters"] as? [String: Any])
        let runUUID = try XCTUnwrap(runParameters["UUID"] as? String)
        let reader = try XCTUnwrap(mainActions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.getitemfromlist"
        })
        let readerParameters = try XCTUnwrap(reader["WFWorkflowActionParameters"] as? [String: Any])
        let input = try XCTUnwrap(readerParameters["WFInput"] as? [String: Any])
        let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
        XCTAssertEqual(inputValue["OutputUUID"] as? String, runUUID)
    }

    func testListFormsValidateOperandTypesAndArity() throws {
        let cases: [(String, String)] = [
            ("(define (main) (length 7))", "length expects a list"),
            ("(define (main) (first \"text\"))", "first expects a list"),
            ("(define (main) (empty? #t))", "empty? expects a list"),
            ("(define (main) (list-ref (list 1) \"one\"))", "list-ref expects a number index"),
            ("(define (main) (list-ref (list 1)))", "list-ref expects 2 arguments, got 1"),
            ("(define (main) (length (list 1) (list 2)))", "length expects 1 argument, got 2"),
            ("(define (main) (list (list 1)))", "list elements cannot be lists"),
            ("(define (main) (+ (list 1) 2))", "+ expects number operands"),
            ("(define (main) (list-ref (list 1) -1))", "list-ref index must be a whole number that is not negative"),
            ("(define (main) (list-ref (list 1) 1.5))", "list-ref index must be a whole number that is not negative")
        ]
        for (source, message) in cases {
            XCTAssertThrowsError(try LongwayCompiler().compile(source), source) { error in
                XCTAssertEqual((error as? LongwayError)?.message, message, source)
            }
        }
    }

    func testListNamesAreReservedForBuiltinForms() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (list a) a)
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "function name 'list' is reserved")
        }
    }

    func testDictionaryLiteralLowersToADictionaryActionWithTypedFields() throws {
        let result = try LongwayCompiler().compile("""
        (define (person)
          (dict "name" "Ada" "born" 1815))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.dictionary",
            "is.workflow.actions.output"
        ])

        let items = try XCTUnwrap(dictionaryFieldItems(in: actions[0]))
        XCTAssertEqual(items.compactMap { $0["WFItemType"] as? Int }, [0, 3])
        XCTAssertEqual(items.compactMap { textTokenLiteral($0["WFKey"]) }, ["name", "born"])
        XCTAssertEqual(items.compactMap { textTokenLiteral($0["WFValue"]) }, ["Ada", "1815"])

        // Unlike a list, a dictionary has its own Shortcut content class.
        XCTAssertEqual(
            propertyList["WFWorkflowOutputContentItemClasses"] as? [String],
            ["WFDictionaryContentItem"]
        )
    }

    func testDictionaryReadsLowerToGetDictionaryValue() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (value) (dict-ref (dict "name" "Ada") "name"))
        (define (keys) (dict-keys (dict "name" "Ada")))
        (define (values) (dict-values (dict "name" "Ada")))
        """)

        var valueTypes: [String: String] = [:]
        for shortcut in program.shortcuts {
            let propertyList = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: shortcut.data, format: nil) as? [String: Any]
            )
            let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
            let dictionaryUUID = try XCTUnwrap(
                (actions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
            )
            XCTAssertEqual(actions[1]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.getvalueforkey")
            let parameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
            valueTypes[shortcut.name] = parameters["WFGetDictionaryValueType"] as? String

            // The read must reference the Dictionary action that produced it.
            let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
            let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
            XCTAssertEqual(inputValue["OutputUUID"] as? String, dictionaryUUID)
        }
        XCTAssertEqual(valueTypes, ["value": "Value", "keys": "All Keys", "values": "All Values"])
    }

    func testDictionaryKeyIsABareStringForALiteralAndATokenForAComputedKey() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (fixed) (dict-ref (dict "name" "Ada") "name"))
        (define (computed key) (dict-ref (dict "name" "Ada") key))
        """)

        // Apple's own shortcuts write a literal key as a bare string.
        let fixed = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: program.shortcuts[0].data, format: nil) as? [String: Any]
        )
        let fixedActions = try XCTUnwrap(fixed["WFWorkflowActions"] as? [[String: Any]])
        let fixedRead = try XCTUnwrap(fixedActions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(fixedRead["WFDictionaryKey"] as? String, "name")

        // A computed key needs the attachment-bearing token string instead.
        let computed = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: program.shortcuts[1].data, format: nil) as? [String: Any]
        )
        let computedActions = try XCTUnwrap(computed["WFWorkflowActions"] as? [[String: Any]])
        // The parameter extraction that reads `key` off Shortcut Input is a
        // Get Dictionary Value too; the dict-ref is the last one.
        let read = try XCTUnwrap(computedActions.last {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.getvalueforkey"
        })
        let parameters = try XCTUnwrap(read["WFWorkflowActionParameters"] as? [String: Any])
        let key = try XCTUnwrap(parameters["WFDictionaryKey"] as? [String: Any])
        XCTAssertEqual(key["WFSerializationType"] as? String, "WFTextTokenString")
        let keyValue = try XCTUnwrap(key["Value"] as? [String: Any])
        let attachments = try XCTUnwrap(keyValue["attachmentsByRange"] as? [String: Any])
        XCTAssertNotNil(attachments["{0, 1}"])
    }

    func testDictionarySetDerivesANewDictionaryFromTheOldOne() throws {
        let result = try LongwayCompiler().compile("""
        (define (renamed)
          (dict-ref (dict-set (dict "name" "Ada") "name" "Grace") "name"))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.dictionary",
            "is.workflow.actions.setvalueforkey",
            "is.workflow.actions.getvalueforkey",
            "is.workflow.actions.output"
        ])

        let dictionaryUUID = try XCTUnwrap(
            (actions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )
        let setParameters = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        // Set Dictionary Value names its input WFDictionary, not the WFInput
        // its Get counterpart uses.
        XCTAssertNil(setParameters["WFInput"])
        let target = try XCTUnwrap(setParameters["WFDictionary"] as? [String: Any])
        let targetValue = try XCTUnwrap(target["Value"] as? [String: Any])
        XCTAssertEqual(targetValue["OutputUUID"] as? String, dictionaryUUID)
        XCTAssertEqual(setParameters["WFDictionaryKey"] as? String, "name")
        XCTAssertEqual(textTokenLiteral(setParameters["WFDictionaryValue"]), "Grace")

        // The read sees the updated dictionary, not the one dict built.
        let setUUID = try XCTUnwrap(setParameters["UUID"] as? String)
        let readParameters = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        let input = try XCTUnwrap(readParameters["WFInput"] as? [String: Any])
        let inputValue = try XCTUnwrap(input["Value"] as? [String: Any])
        XCTAssertEqual(inputValue["OutputUUID"] as? String, setUUID)
    }

    func testDictionaryFieldCarriesNestedListsAndDictionaries() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (inner) (dict "name" "Ada"))
        (define (record)
          (dict "languages" (list "Analytical Engine") "person" (inner)))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: program.shortcuts[1].data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let build = try XCTUnwrap(actions.last { action in
            action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.dictionary"
        })
        let items = try XCTUnwrap(dictionaryFieldItems(in: build))

        // WorkflowKit numbers these item types 1 dictionary and 2 array, and
        // substitutes a whole-field variable through the matching state class.
        // A text field would flatten the list to newline-joined text and the
        // dictionary to JSON.
        XCTAssertEqual(items.compactMap { $0["WFItemType"] as? Int }, [2, 1])
        let list = try XCTUnwrap(items[0]["WFValue"] as? [String: Any])
        XCTAssertEqual(list["WFSerializationType"] as? String, "WFArraySubstitutableParameterState")
        let nested = try XCTUnwrap(items[1]["WFValue"] as? [String: Any])
        XCTAssertEqual(nested["WFSerializationType"] as? String, "WFDictionarySubstitutableParameterState")
    }

    func testDictionaryCrossesAFunctionCallAsADictionaryTypedArgument() throws {
        let program = try LongwayCompiler().compileProgram("""
        (define (label-of record) (dict-ref record "name"))
        (define (main) (label-of (dict "name" "Ada")))
        """)

        // The callee's parameter is inferred as a dictionary, so the caller
        // must hand it over through the dictionary-typed field rather than
        // through a text field that would flatten it to JSON.
        let caller = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: program.shortcuts[1].data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(caller["WFWorkflowActions"] as? [[String: Any]])
        let build = try XCTUnwrap(actions.first)
        let buildUUID = try XCTUnwrap(
            (build["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )
        let arguments = try XCTUnwrap(actions.first { action in
            (action["WFWorkflowActionParameters"] as? [String: Any])?["CustomOutputName"] as? String == "Arguments"
        })
        let items = try XCTUnwrap(dictionaryFieldItems(in: arguments))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["WFItemType"] as? Int, 1)
        XCTAssertEqual(textTokenLiteral(items[0]["WFKey"]), "record")

        let value = try XCTUnwrap(items[0]["WFValue"] as? [String: Any])
        XCTAssertEqual(value["WFSerializationType"] as? String, "WFDictionarySubstitutableParameterState")
        let attachment = try XCTUnwrap(value["Value"] as? [String: Any])
        XCTAssertEqual(attachment["WFSerializationType"] as? String, "WFTextTokenAttachment")
        let reference = try XCTUnwrap(attachment["Value"] as? [String: Any])
        XCTAssertEqual(reference["OutputUUID"] as? String, buildUUID)
    }

    func testDictionaryPassesThroughGetVariableRatherThanText() throws {
        // Text or Number would flatten a dictionary to JSON, so a dictionary
        // written to a tail-call loop variable goes through Get Variable.
        let result = try LongwayCompiler().compile("""
        (define (walk record index)
          (if (= index 0)
              (dict-ref record "name")
              (walk record (- index 1))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let identifiers = actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String }
        XCTAssertTrue(identifiers.contains("is.workflow.actions.repeat.count"))

        let recordWrites = actions.filter { action in
            guard action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.setvariable" else {
                return false
            }
            let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
            return parameters?["WFVariableName"] as? String == "record"
        }
        XCTAssertEqual(recordWrites.count, 2, "the dictionary is seeded once and rewritten once per iteration")

        // Every value published for the loop variable must come from a
        // Get Variable passthrough, never from a Text or Number action.
        for write in recordWrites {
            let parameters = try XCTUnwrap(write["WFWorkflowActionParameters"] as? [String: Any])
            let input = try XCTUnwrap(parameters["WFInput"] as? [String: Any])
            let value = try XCTUnwrap(input["Value"] as? [String: Any])
            let uuid = try XCTUnwrap(value["OutputUUID"] as? String)
            let producer = try XCTUnwrap(actions.first { action in
                (action["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String == uuid
            })
            XCTAssertEqual(
                producer["WFWorkflowActionIdentifier"] as? String,
                "is.workflow.actions.getvariable"
            )
        }
    }

    func testDictionaryFormsValidateOperandTypesAndArity() throws {
        let cases: [(String, String)] = [
            ("(define (main) (dict-ref 7 \"k\"))", "dict-ref expects a dictionary"),
            ("(define (main) (dict-keys \"text\"))", "dict-keys expects a dictionary"),
            ("(define (main) (dict-values (list 1)))", "dict-values expects a dictionary"),
            ("(define (main) (dict-ref (dict \"k\" 1) 2))", "dict-ref expects a text key"),
            ("(define (main) (dict \"k\"))", "dict expects alternating keys and values, got 1 forms"),
            ("(define (main) (dict 1 2))", "dict expects a text key"),
            ("(define (main) (dict \"k\" 1 \"k\" 2))", "duplicate dict key 'k'"),
            ("(define (main) (dict-ref (dict \"k\" 1)))", "dict-ref expects 2 arguments, got 1"),
            ("(define (main) (dict-keys (dict \"k\" 1) (dict \"j\" 2)))", "dict-keys expects 1 argument, got 2"),
            ("(define (main) (dict-set (dict \"k\" 1) \"k\"))", "dict-set expects 3 arguments, got 2"),
            (
                "(define (main) (dict-set (dict \"k\" 1) \"k\" (list 1)))",
                "dict-set cannot store lists; build the dictionary with dict instead"
            ),
            (
                "(define (main) (dict-set (dict \"k\" 1) \"k\" (dict \"j\" 2)))",
                "dict-set cannot store dictionaries; build the dictionary with dict instead"
            ),
            ("(define (main) (list (dict \"k\" 1)))", "list elements cannot be dictionaries"),
            ("(define (main) (+ (dict \"k\" 1) 2))", "+ expects number operands")
        ]
        for (source, message) in cases {
            XCTAssertThrowsError(try LongwayCompiler().compile(source), source) { error in
                XCTAssertEqual((error as? LongwayError)?.message, message, source)
            }
        }
    }

    func testDictionaryNamesAreReservedForBuiltinForms() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (dict-ref a) a)
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "function name 'dict-ref' is reserved")
        }
    }

    func testDynamicTextBuildsOneTokenStringWithUTF16AttachmentRanges() throws {
        let result = try LongwayCompiler().compile("""
        (define (entry name amount)
          (string-append "💰: " name " " (number->text amount)))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let textActions = actions.filter {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.gettext"
        }
        XCTAssertEqual(textActions.count, 2)

        let finalParameters = try XCTUnwrap(textActions.last?["WFWorkflowActionParameters"] as? [String: Any])
        let token = try XCTUnwrap(finalParameters["WFTextActionText"] as? [String: Any])
        let value = try XCTUnwrap(token["Value"] as? [String: Any])
        XCTAssertEqual(value["string"] as? String, "💰: \u{FFFC} \u{FFFC}")
        let attachments = try XCTUnwrap(value["attachmentsByRange"] as? [String: Any])
        XCTAssertNotNil(attachments["{4, 1}"], "emoji occupies two UTF-16 code units")
        XCTAssertNotNil(attachments["{6, 1}"])
    }

    func testTextSplittingAndInteractiveChoiceUseClipboardConfirmedShapes() throws {
        let result = try LongwayCompiler().compile("""
        (define (choose-account)
          (let ((menu (split-lines "Cash | Assets:Cash USD\\nCard | Liabilities:Card USD")))
            (split-whitespace
              (last (split-text (choose-from-list menu "Account") " | ")))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let splitActions = actions.filter {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.text.split"
        }
        XCTAssertEqual(splitActions.count, 3)

        let lineParameters = try XCTUnwrap(splitActions[0]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertNil(lineParameters["WFTextSeparator"])
        let customParameters = try XCTUnwrap(splitActions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(customParameters["WFTextSeparator"] as? String, "Custom")
        XCTAssertEqual(customParameters["WFTextCustomSeparator"] as? String, " | ")
        let spaceParameters = try XCTUnwrap(splitActions[2]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(spaceParameters["WFTextSeparator"] as? String, "Spaces")

        let chooser = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.choosefromlist"
        })
        let chooserParameters = try XCTUnwrap(chooser["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(chooserParameters["WFChooseFromListActionPrompt"] as? String, "Account")
        XCTAssertNotNil(chooserParameters["WFInput"] as? [String: Any])
    }

    func testAskAndCurrentDateFormattingUseTypedParameters() throws {
        let result = try LongwayCompiler().compile("""
        (define (entry)
          (let ((amount (ask-number "Amount")))
            (let ((payee (ask-text "Payee")))
              (let ((date (format-current-date "yyyy-MM-dd")))
                (string-append date " " payee " " (number->text amount))))))
        """)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let asks = actions.filter { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.ask" }
        XCTAssertEqual(asks.count, 2)
        let numberParameters = try XCTUnwrap(asks[0]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(numberParameters["WFAskActionPrompt"] as? String, "Amount")
        XCTAssertEqual(numberParameters["WFInputType"] as? String, "Number")
        let textParameters = try XCTUnwrap(asks[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(textParameters["WFAskActionPrompt"] as? String, "Payee")
        XCTAssertNil(textParameters["WFInputType"])

        let dateAction = try XCTUnwrap(actions.first {
            $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.format.date"
        })
        let dateParameters = try XCTUnwrap(dateAction["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(dateParameters["WFDateFormatStyle"] as? String, "Custom")
        XCTAssertEqual(dateParameters["WFDateFormat"] as? String, "yyyy-MM-dd")
        let date = try XCTUnwrap(dateParameters["WFDate"] as? [String: Any])
        let dateValue = try XCTUnwrap(date["Value"] as? [String: Any])
        let dateAttachments = try XCTUnwrap(dateValue["attachmentsByRange"] as? [String: Any])
        let currentDate = try XCTUnwrap(dateAttachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(currentDate["Type"] as? String, "CurrentDate")
    }

    func testTextAndInputFormsValidateTypesAndLiteralParameters() throws {
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (bad) (string-append "amount" 1))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "string-append expects text operands")
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (bad separator) (split-text "a,b" separator))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "split-text separator must be a string literal")
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (bad prompt) (ask-text prompt))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "ask-text prompt must be a string literal")
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (bad) (choose-from-list "not a list" "Pick"))
        """)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "choose-from-list expects a list")
        }
    }

    func testDeclarativeActionCatalogRendersTypedArgumentsAndResults() throws {
        let catalog = try ActionCatalog(data: Data("""
        {
          "version": 1,
          "actions": [{
            "name": "sample-echo",
            "arguments": [{"name": "text", "type": "text"}],
            "result": {"type": "text", "outputName": "Echo", "runtimeTyped": true},
            "sideEffect": false,
            "template": {
              "WFWorkflowActionIdentifier": "com.example.EchoIntent",
              "WFWorkflowActionParameters": {
                "UUID": {"$longway": "uuid"},
                "text": {"$longway": "argument", "name": "text", "encoding": "text-token"},
                "mode": "exact",
                "limit": 3
              }
            }
          }]
        }
        """.utf8))
        let result = try LongwayCompiler().compile("""
        (define (test)
          (let ((message "hello"))
            (sample-echo message)))
        """, catalog: catalog)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["WFWorkflowActionIdentifier"] as? String }, [
            "is.workflow.actions.gettext",
            "com.example.EchoIntent",
            "is.workflow.actions.output"
        ])

        let textUUID = try XCTUnwrap(
            (actions[0]["WFWorkflowActionParameters"] as? [String: Any])?["UUID"] as? String
        )
        let external = try XCTUnwrap(actions[1]["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(external["mode"] as? String, "exact")
        XCTAssertEqual(external["limit"] as? Int, 3)
        let externalUUID = try XCTUnwrap(external["UUID"] as? String)
        let token = try XCTUnwrap(external["text"] as? [String: Any])
        let tokenValue = try XCTUnwrap(token["Value"] as? [String: Any])
        let tokenAttachments = try XCTUnwrap(tokenValue["attachmentsByRange"] as? [String: Any])
        let tokenAttachment = try XCTUnwrap(tokenAttachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(tokenAttachment["OutputUUID"] as? String, textUUID)

        let outputParameters = try XCTUnwrap(actions[2]["WFWorkflowActionParameters"] as? [String: Any])
        let output = try XCTUnwrap(outputParameters["WFOutput"] as? [String: Any])
        let outputValue = try XCTUnwrap(output["Value"] as? [String: Any])
        let outputAttachments = try XCTUnwrap(outputValue["attachmentsByRange"] as? [String: Any])
        let outputAttachment = try XCTUnwrap(outputAttachments["{0, 1}"] as? [String: Any])
        XCTAssertEqual(outputAttachment["OutputName"] as? String, "Echo")
        XCTAssertEqual(outputAttachment["OutputUUID"] as? String, externalUUID)
    }

    func testWorkingCopyCatalogWiresRepositoryInputsExplicitly() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try ActionCatalog(contentsOf: [
            projectRoot.appendingPathComponent("Actions/WorkingCopy.longway-actions.json")
        ])
        let result = try LongwayCompiler().compile("""
        (define (save)
          (let ((repository (working-copy-append-file "beancount-ledger" "ledger/entry.txt" "entry")))
            (working-copy-commit repository "record entry")
            (working-copy-pull repository)
            (working-copy-push repository)
            "done"))
        """, catalog: catalog)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let write = try XCTUnwrap(actions.first {
            ($0["WFWorkflowActionIdentifier"] as? String)?.hasSuffix("WriteFileEntityAppIntent") == true
        })
        let writeParameters = try XCTUnwrap(write["WFWorkflowActionParameters"] as? [String: Any])
        let writeUUID = try XCTUnwrap(writeParameters["UUID"] as? String)
        let selectedRepository = try XCTUnwrap(writeParameters["repo"] as? [String: Any])
        XCTAssertEqual(selectedRepository["identifier"] as? String, "beancount-ledger")
        XCTAssertEqual((selectedRepository["title"] as? [String: Any])?["key"] as? String, "beancount-ledger")

        let repositoryConsumers = actions.filter {
            guard let identifier = $0["WFWorkflowActionIdentifier"] as? String else { return false }
            return identifier.hasSuffix("CommitRepositoryEntityAppIntent")
                || identifier.hasSuffix("PullRepositoryEntityAppIntent")
                || identifier.hasSuffix("PushRepositoryEntityAppIntent")
        }
        XCTAssertEqual(repositoryConsumers.count, 3)
        for action in repositoryConsumers {
            let parameters = try XCTUnwrap(action["WFWorkflowActionParameters"] as? [String: Any])
            let repository = try XCTUnwrap(parameters["repo"] as? [String: Any])
            let value = try XCTUnwrap(repository["Value"] as? [String: Any])
            XCTAssertEqual(value["OutputUUID"] as? String, writeUUID)
        }
    }

    func testDeclarativeActionCatalogValidatesTypesAndValueUsage() throws {
        let catalog = try ActionCatalog(data: Data("""
        {
          "version": 1,
          "actions": [{
            "name": "sample-notify",
            "arguments": [{"name": "message", "type": "text"}],
            "sideEffect": true,
            "template": {
              "WFWorkflowActionIdentifier": "com.example.NotifyIntent",
              "WFWorkflowActionParameters": {
                "UUID": {"$longway": "uuid"},
                "message": {"$longway": "argument", "name": "message", "encoding": "literal"}
              }
            }
          }]
        }
        """.utf8))

        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (bad) (sample-notify 1) "done")
        """, catalog: catalog)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "sample-notify argument 1 expects text")
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (bad) (sample-notify "hello"))
        """, catalog: catalog)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "external action 'sample-notify' does not produce a value")
        }
        XCTAssertThrowsError(try LongwayCompiler().compile("""
        (define (sample-notify) "conflict")
        """, catalog: catalog)) { error in
            XCTAssertEqual((error as? LongwayError)?.message, "function name 'sample-notify' is reserved")
        }
    }

    func testCatalogSideEffectsDisableTailCallOptimization() throws {
        let catalog = try ActionCatalog(data: Data("""
        {
          "version": 1,
          "actions": [{
            "name": "sample-prompt",
            "arguments": [{"name": "prompt", "type": "text"}],
            "result": {"type": "text", "outputName": "Answer"},
            "sideEffect": true,
            "template": {
              "WFWorkflowActionIdentifier": "com.example.PromptIntent",
              "WFWorkflowActionParameters": {
                "UUID": {"$longway": "uuid"},
                "prompt": {"$longway": "argument", "name": "prompt", "encoding": "text-token"}
              }
            }
          }]
        }
        """.utf8))
        let result = try LongwayCompiler().compile("""
        (define (retry n)
          (if (= n 0)
              "done"
              (let ((answer (sample-prompt "Continue?")))
                (retry (- n 1)))))
        """, catalog: catalog)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(propertyList["WFWorkflowActions"] as? [[String: Any]])
        let identifiers = actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String }
        XCTAssertTrue(identifiers.contains("com.example.PromptIntent"))
        XCTAssertTrue(identifiers.contains("is.workflow.actions.runworkflow"))
        XCTAssertFalse(identifiers.contains("is.workflow.actions.repeat.count"))
    }

    func testActionCatalogRejectsInvalidTemplates() throws {
        XCTAssertThrowsError(try ActionCatalog(data: Data("""
        {
          "version": 1,
          "actions": [{
            "name": "if",
            "arguments": [],
            "template": {
              "WFWorkflowActionIdentifier": "com.example.BadIntent",
              "WFWorkflowActionParameters": {"UUID": {"$longway": "uuid"}}
            }
          }]
        }
        """.utf8))) { error in
            XCTAssertEqual(
                (error as? ActionCatalogError)?.message,
                "external action 'if' conflicts with a built-in form"
            )
        }
        XCTAssertThrowsError(try ActionCatalog(data: Data("""
        {
          "version": 1,
          "actions": [{
            "name": "broken",
            "arguments": [{"name": "value", "type": "text"}],
            "template": {
              "WFWorkflowActionIdentifier": "com.example.BadIntent",
              "WFWorkflowActionParameters": {"UUID": {"$longway": "uuid"}}
            }
          }]
        }
        """.utf8))) { error in
            XCTAssertEqual(
                (error as? ActionCatalogError)?.message,
                "external action 'broken' has unused arguments: value"
            )
        }
    }

    func testShortcutActionExtractorReadsUnsignedWorkflowPlists() throws {
        let workflow: [String: Any] = [
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
                    "WFWorkflowActionParameters": ["WFTextActionText": "hello"]
                ],
                [
                    "WFWorkflowActionIdentifier": "com.example.SampleIntent",
                    "WFWorkflowActionParameters": ["enabled": true]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: workflow,
            format: .binary,
            options: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("longway-extractor-\(UUID().uuidString).shortcut")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let actions = try ShortcutActionExtractor().extract(from: url)
        XCTAssertEqual(actions.map(\.index), [0, 1])
        XCTAssertEqual(actions.map(\.identifier), [
            "is.workflow.actions.gettext",
            "com.example.SampleIntent"
        ])
        let extracted = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: actions[1].propertyListData,
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(extracted["WFWorkflowActionIdentifier"] as? String, "com.example.SampleIntent")
    }

    private func dictionaryFieldItems(in action: [String: Any]) -> [[String: Any]]? {
        let parameters = action["WFWorkflowActionParameters"] as? [String: Any]
        let items = parameters?["WFItems"] as? [String: Any]
        let value = items?["Value"] as? [String: Any]
        return value?["WFDictionaryFieldValueItems"] as? [[String: Any]]
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
