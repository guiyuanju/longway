# Longway

Longway is a small, Scheme-inspired language that compiles to Apple Shortcut files. The compiler and CLI are written in Swift.

This repository is an MVP: it provides a readable S-expression DSL, useful source diagnostics, binary/XML property-list generation, and optional signing through Apple's `shortcuts` CLI. It is not yet a complete Scheme implementation.

## Quick start

Longway requires macOS 13+ and Swift 6.

```sh
swift build -c release
.build/release/longway check Examples/hello.longway
.build/release/longway build Examples/hello.longway
```

The build command writes `Examples/hello.shortcut`. By default this is an unsigned binary Shortcut, which is useful for inspecting compiler output:

```sh
plutil -p Examples/hello.shortcut
```

To produce a file that Apple's Shortcuts app can import, ask Apple's command-line tool to sign it:

```sh
.build/release/longway build Examples/hello.longway \
  -o Hello.shortcut --sign
open Hello.shortcut
```

Signing is an Apple service. It may require an Apple ID, network access, and permission to share shortcuts. Longway leaves any existing destination untouched if signing fails.

## Language

A source file contains one `shortcut` form. Longway uses explicit function-like arguments and compiles them to the actions and magic-variable references required by Shortcuts.

A literal passed to an action is embedded directly:

```scheme
; comments start with a semicolon
(shortcut "Hello Longway"
  (show-result "Hello from Longway!"))
```

A string bound with `let` is materialized as a Text action. References to that binding compile to the Text action's UUID:

```scheme
(shortcut "Hello Longway"
  (let ((content "Hello from Longway!"))
    (show-result content)))
```

Bindings are lexically scoped. A `let` may contain multiple bindings and body forms; its initializers use the outer scope, as in Scheme `let` rather than `let*`.

Math uses prefix expressions with at least two operands. Operations are evaluated from left to right and compile to explicit Number and Calculate actions:

```scheme
(shortcut "Math"
  (let ((x 10)
        (y 4))
    (show-result (* (+ x y) 2))))
```

Logical expressions use `#t` and `#f`. `and` and `or` short-circuit by compiling to nested Shortcut If blocks; `not` compiles to one If/Otherwise/End If block:

```scheme
(shortcut "Logic"
  (let ((enabled #t))
    (show-result (and enabled (not #f)))))
```

Supported MVP forms:

| Longway form | Apple Shortcut action |
| --- | --- |
| `(show-result "value")` | Show Result with a literal parameter |
| `(let ((name value)) …)` | Materialized Text/Number values plus UUID references |
| `(+ a b …)`, `(- a b …)` | Add or subtract numbers |
| `(* a b …)`, `(/ a b …)` | Multiply or divide numbers |
| `(and a b …)`, `(or a b …)` | Short-circuit Boolean operations |
| `(not value)` | Boolean negation |
| `(notification "message")` | Show Notification |
| `(open-url "https://…")` | URL, then Open URLs |
| `(wait 1.5)` | Wait |

Strings support `\n`, `\r`, `\t`, `\"`, and `\\`. Booleans (`#t`, `#f`) are tokenized for future forms but are not used by the MVP actions.

## CLI

```text
longway build <file.longway> [-o output.shortcut] [--xml]
              [--sign[=anyone|people-who-know-me]]
longway check <file.longway>
longway version
```

- `build` parses, validates, and emits a `.shortcut` property list.
- `check` validates source without writing a file.
- `--xml` emits a human-readable XML property list instead of the default binary format.
- `--sign` invokes `/usr/bin/shortcuts sign`; it is intentionally opt-in because signing calls an Apple service. It defaults to `people-who-know-me`; use `--sign=anyone` for public sharing.

## Project layout

- `Sources/LongwayCore` — lexer, parser, semantic validation, and Shortcut emitter
- `Sources/LongwayCLI` — dependency-free command-line interface and Apple signer integration
- `Tests/LongwayCoreTests` — parser/compiler tests
- `Examples` — sample Longway programs

## MVP boundaries

Longway currently supports lexical string, number, and Boolean bindings; arithmetic and logical expressions; and a small set of action calls. Source-level conditionals, loops, user-defined functions/macros, Shortcut inputs, richer value types, and a larger action catalog are natural next steps.
