# Longway Agent Notes

## Product direction

- Longway is a Swift compiler for a Scheme-inspired language that emits Apple Shortcut property lists.
- Keep the source language in a normal programming model. Apple Shortcuts actions, UUIDs, and magic-variable wiring are compiler implementation details rather than source-level workflow syntax.
- Ship and verify a focused MVP before expanding the action catalog or language surface.

## Language semantics

- A program contains one or more `(define (name parameters …) body … result)` forms. Each definition compiles to a standalone Shortcut named after the function; legacy `(shortcut …)` forms are invalid.
- Parameters and return values have no source-level type annotations. Infer number, text, and Boolean constraints across function bodies and recursive call graphs; leave genuinely unconstrained values generic and reject only provable conflicts.
- The final form produces the function result. Earlier forms may perform actions for side effects; a final `show-result` both shows and returns its argument.
- Direct and mutual recursion are valid. Calls are name-linked to independently installed Shortcut artifacts. A definition whose entire body is one direct self-call in tail position (through `let` and `if`, with no `notification`/`open-url`/`wait`/`show-result` on that path) is tail-call optimized into a bounded in-workflow loop instead; everything else — mutual recursion, non-tail self-calls, multi-form bodies — keeps calling the generated Shortcut recursively and is not tail-call optimized.
- Embed direct literals in consuming action parameters when the parameter schema permits it; do not materialize them merely to make them referenceable.
- A `let` binding materializes a value as a UUID-bearing Shortcut action so other expressions can reference it. Bound literals emit Text or Number actions; references serialize the producer action's output UUID.
- Do not rely on implicit previous-action output. Every generated dependency must be wired explicitly.
- `let` is lexically scoped and follows Scheme `let` initializer semantics: initializers see the outer environment, not sibling bindings. Shadowing in nested scopes is allowed; duplicate names in one binding list are errors.
- `(text ...)` is not a public statement and `(show-result)` without an argument is invalid.
- Numeric `=`, `<`, `<=`, `>`, and `>=` accept at least two operands and compare each adjacent pair, matching Scheme-style chained comparison semantics.
- `if` requires a Boolean condition, consequent, and alternative. It can select values with compatible inferred types or select action forms; only the selected branch executes.
- Preserve source locations in semantic diagnostics.

## Shortcut lowering invariants

- Use `is.workflow.actions.gettext` for Text actions.
- Serialize literal text as `WFTextTokenString` with an empty `attachmentsByRange` dictionary.
- Serialize an action-output text reference as a `WFTextTokenString` containing one object-replacement character and an attachment with `Type`, `OutputName`, and `OutputUUID`.
- Lower `+`, `-`, `*`, and `/` expressions with at least two operands to explicit `is.workflow.actions.math` actions. Materialize a literal left operand with `is.workflow.actions.number`, chain variadic operations left-to-right, and identify each result as `Calculation Result`.
- Lower numeric `<`, `<=`, `>`, `>=`, and `=` with Shortcut condition codes 0, 1, 2, 3, and 4. Code 4 renders as Shortcut’s `is` condition and performs equality on a typed Number input. Chain variadic comparisons through nested short-circuit conditional blocks.
- Shortcut Input dictionary extraction and Run Shortcut results are runtime-generic even when Longway inferred a concrete type. Pass them through Number or Text before using them as typed conditional inputs.
- Numeric conditional right-hand action outputs serialize under `WFConditionalActionString` as token strings, not under `WFNumberValue`. For relational conditions, materialize literal zero first because Shortcuts imports a direct zero comparison value as an unset required field; direct equality uses code 4 with a literal `WFNumberValue` zero.
- Represent Boolean values as typed Text producers containing `#t` or `#f`. Lower `not`, short-circuit `and`, short-circuit `or`, and source `if` to `is.workflow.actions.conditional` blocks sharing a `GroupingIdentifier`; typed value conditionals reference the End If UUID as `If Result`.
- Ensure each value-producing `if` branch ends with an action of the branch type. Pass referenced Text/Boolean values through Text and referenced Number values through Number so Shortcuts gives `If Result` the intended runtime value.
- Conditional `WFInput` must wrap the `WFTextTokenAttachment` as `{ Type: "Variable", Variable: attachment }`. A bare attachment passes plist validation but imports with an unset If condition.
- Functions with parameters enable `WFWorkflowHasShortcutInputVariables`, accept `WFDictionaryContentItem`, and read each named argument with `is.workflow.actions.getvalueforkey` from a `Type: ExtensionInput` attachment.
- Lower a function call to `is.workflow.actions.dictionary` followed by `is.workflow.actions.runworkflow` with explicit `WFInput`, `WFWorkflowName`, UUID, and output name. Recursive calls use the same mechanism, except tail-recursive self-calls (see below).
- Lower a tail-call-optimized definition to `is.workflow.actions.setvariable`/`is.workflow.actions.getvariable` on one named Shortcuts variable per parameter (referenced as `{ Type: "Variable", VariableName: <parameter name> }`, distinct from the `{ Type: "ActionOutput", OutputName, OutputUUID }` shape used everywhere else) plus a hidden `#result` variable — `#` cannot start a source identifier, so it can never collide with a real parameter. Wrap the per-iteration body in `is.workflow.actions.repeat.count` (`GroupingIdentifier` + `WFControlFlowMode` 0/2, `WFRepeatCount` = `tailCallLoopLimit`) rather than a recursive `runworkflow` call. Always force a concrete runtime type (`emitValue`, not the passthrough `materialize`) before writing to a loop variable. Named-variable Get Variable reads are still runtime-generic to the Shortcuts editor even though a concrete type was written (`isRuntimeTyped: false`, exactly like dictionary extraction and Run Shortcut results): skipping that and trusting the read directly compiles fine but silently produces a conditional whose input type Shortcuts can't infer, which the editor renders as a vague "is anything" condition instead of "is 0". A base case ends with `is.workflow.actions.exit` ("Stop This Shortcut", confirmed to need no parameters via joshfarrant/shortcuts-js's `exitShortcut.ts`) right after recording `#result`, so the loop only actually runs as many iterations as the recursion needs; `WFRepeatCount` = `tailCallLoopLimit` is a safety cap for recursion that never reaches a base case, not the expected iteration count. Side-effecting actions on the path to the self-call still disqualify optimization even though a correctly-firing exit would make the base-case side of that safe: value correctness degrades gracefully if exit somehow doesn't unwind out of the nested Repeat/Conditional blocks as documented (the loop just falls through to the existing bound-and-read-`#result` path, unchanged), but a side effect firing on every remaining idle iteration instead of once would not degrade gracefully — and exit's behavior from this nesting depth has not been confirmed on a real device.
- End every function with `is.workflow.actions.output`. Set workflow output content classes from the inferred return type, or emit the supported generic classes when inference leaves it unconstrained.
- Keep function shortcuts out of the Share Sheet by emitting empty `WFWorkflowTypes`.
- Signing remains opt-in through Apple's `shortcuts sign` command. Sign every artifact before writing destinations, and replace each destination atomically so a failed signer does not destroy existing files.
- Generated `.shortcut` artifacts are ignored and should be rebuilt rather than committed.

## Verification

Run these before claiming a compiler change is complete:

```sh
swift test
swift build -c release
.build/release/longway check Examples/hello.longway
.build/release/longway check Examples/morning.longway
.build/release/longway check Examples/math.longway
.build/release/longway check Examples/logic.longway
.build/release/longway check Examples/comparison.longway
.build/release/longway check Examples/conditional.longway
.build/release/longway check Examples/functions.longway
.build/release/longway check Examples/identity.longway
```

For serialization changes, inspect the emitted unsigned plist and verify UUID references point to the intended producer action. When signing behavior changes, exercise the real Apple signer against an existing destination.

For function ABI, recursion, runtime typing, or conditional serialization changes, signing and import preview are not sufficient verification. Replace the installed artifacts, confirm their names have no automatic numeric suffix, and run a finite caller through `/usr/bin/shortcuts run`; verify both its returned value and termination. A visible magic-variable label does not prove that Shortcuts resolved its runtime value.

The tail-call loop lowering specifically has not yet been run through the real Shortcuts app (signing plus `shortcuts run` needs an interactive Apple ID) — it is only verified against the unsigned plist structure via `swift test`. Before relying on it, sign and run `Examples/functions.longway`'s `sum-to` (e.g. `sum-to 10 0` should return `55`) through `/usr/bin/shortcuts run`, and separately confirm a case near/above `tailCallLoopLimit` behaves as documented (returns the accumulator's state at the bound, not a crash) rather than assuming the plist shapes for `is.workflow.actions.setvariable`/`getvariable`/`repeat.count`/`exit` researched from third-party Shortcuts-format documentation are exactly right. In particular, confirm `is.workflow.actions.exit` genuinely unwinds out of the nested `repeat.count`/`conditional` GroupingIdentifier blocks it's fired from rather than only skipping the rest of the innermost block — e.g. by checking that `sum-to 3 0` stops after a handful of actions rather than visibly iterating toward 2000.

## Known platform issue

The Shortcuts file-open import preview can crash in AppKit with a repeated window-layout exception, while drag-and-drop imports the same signed artifact. This has not been causally tied to one plist field and must not be reported as fixed without repeatable runtime evidence. Use drag-and-drop as the current manual import workaround.
