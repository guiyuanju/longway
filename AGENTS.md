# Longway Agent Notes

## Product direction

- Longway is a Swift compiler for a Scheme-inspired language that emits Apple Shortcut property lists.
- Keep the source language in a normal programming model. Apple Shortcuts actions, UUIDs, and magic-variable wiring are compiler implementation details rather than source-level workflow syntax.
- Ship and verify a focused MVP before expanding the action catalog or language surface.

## Language semantics

- Direct literals are embedded directly in action parameters. For example, `(show-result "Hello")` emits one Show Result action with a literal `Text` parameter.
- A `let` binding materializes a value as a UUID-bearing Shortcut action so other expressions can reference it. Bound literals emit Text or Number actions; references serialize the producer action's output UUID.
- Do not rely on implicit previous-action output. Every generated dependency must be wired explicitly.
- `let` is lexically scoped and follows Scheme `let` initializer semantics: initializers see the outer environment, not sibling bindings. Shadowing in nested scopes is allowed; duplicate names in one binding list are errors.
- `(text ...)` is not a public statement and `(show-result)` without an argument is invalid.
- Preserve source locations in semantic diagnostics.

## Shortcut lowering invariants

- Use `is.workflow.actions.gettext` for Text actions.
- Serialize literal text as `WFTextTokenString` with an empty `attachmentsByRange` dictionary.
- Serialize an action-output text reference as a `WFTextTokenString` containing one object-replacement character and an attachment with `Type`, `OutputName`, and `OutputUUID`.
- Lower `+`, `-`, `*`, and `/` expressions with at least two operands to explicit `is.workflow.actions.math` actions. Materialize a literal left operand with `is.workflow.actions.number`, chain variadic operations left-to-right, and identify each result as `Calculation Result`.
- Represent Boolean values as typed Text producers containing `#t` or `#f`. Lower `not`, short-circuit `and`, and short-circuit `or` to `is.workflow.actions.conditional` blocks sharing a `GroupingIdentifier`; reference the End If UUID as `If Result`.
- Conditional `WFInput` must wrap the `WFTextTokenAttachment` as `{ Type: "Variable", Variable: attachment }`. A bare attachment passes plist validation but imports with an unset If condition.
- Keep normal shortcuts out of the Share Sheet by emitting empty `WFWorkflowTypes` and disabling shortcut input variables.
- Signing remains opt-in through Apple's `shortcuts sign` command. Replacing a signed destination must be atomic so a failed replacement does not destroy the existing file.
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
```

For serialization changes, inspect the emitted unsigned plist and verify UUID references point to the intended producer action. When signing behavior changes, exercise the real Apple signer against an existing destination.

## Known platform issue

The Shortcuts file-open import preview can crash in AppKit with a repeated window-layout exception, while drag-and-drop imports the same signed artifact. This has not been causally tied to one plist field and must not be reported as fixed without repeatable runtime evidence. Use drag-and-drop as the current manual import workaround.
