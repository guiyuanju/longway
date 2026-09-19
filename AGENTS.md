# Longway Agent Notes

## Product direction

- Longway is a Swift compiler for a Scheme-inspired language that emits Apple Shortcut property lists.
- Keep the source language in a normal programming model. Apple Shortcuts actions, UUIDs, and magic-variable wiring are compiler implementation details rather than source-level workflow syntax.
- Ship and verify a focused MVP before expanding the action catalog or language surface.

## Language semantics

- A program contains one or more `(define (name parameters …) body … result)` forms. Each definition compiles to a standalone Shortcut named after the function; legacy `(shortcut …)` forms are invalid.
- Parameters and return values have no source-level type annotations. Infer number, text, and Boolean constraints across function bodies and recursive call graphs; leave genuinely unconstrained values generic and reject only provable conflicts.
- The final form produces the function result. Earlier forms may perform actions for side effects; a final `show-result` both shows and returns its argument.
- Direct and mutual recursion are valid. Calls are name-linked to independently installed Shortcut artifacts and are not tail-call optimized.
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
- Lower a function call to `is.workflow.actions.dictionary` followed by `is.workflow.actions.runworkflow` with explicit `WFInput`, `WFWorkflowName`, UUID, and output name. Recursive calls use the same mechanism.
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

## Known platform issue

The Shortcuts file-open import preview can crash in AppKit with a repeated window-layout exception, while drag-and-drop imports the same signed artifact. This has not been causally tied to one plist field and must not be reported as fixed without repeatable runtime evidence. Use drag-and-drop as the current manual import workaround.
