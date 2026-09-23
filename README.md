# Longway

A small Scheme-inspired language that compiles to Apple Shortcuts. Written in Swift.

Longway is an MVP, not a complete Scheme: S-expressions, type inference,
source-located diagnostics, property-list output, and optional signing through
Apple's `shortcuts` CLI.

```scheme
(define (sum-to n acc)
  (if (= n 0)
      acc
      (sum-to (- n 1) (+ acc n))))

(define (sum-to-ten)
  (show-result (sum-to 10 0)))
```

That is `Examples/functions.longway`, verbatim.

## Quick start

Requires macOS 13+ and Swift 6.

```sh
swift build -c release
.build/release/longway check Examples/functions.longway
.build/release/longway build Examples/functions.longway
```

Each `define` becomes one standalone Shortcut, written to `<source>.shortcuts/`:

```text
Examples/functions.shortcuts/
├── sum-to.shortcut
└── sum-to-ten.shortcut
```

Inspect unsigned output with `plutil -p <file>`. To import into the Shortcuts
app, sign it — an Apple service that may need an Apple ID and network access:

```sh
.build/release/longway build Examples/functions.longway -o Functions --sign
open Functions/sum-to.shortcut
```

## Language reference

| Form | Meaning |
| --- | --- |
| `(define (name args …) body … result)` | Compile one standalone function Shortcut |
| `(name args …)` | Call another generated function Shortcut |
| `(let ((name value) …) body …)` | Bind values; initializers see the outer scope |
| `(let* ((name value) …) body …)` | Bind sequentially; each initializer sees the previous |
| `(if condition consequent alternative)` | Lazily select a value or action branch |
| `(+ a b …)`, `(- a b …)`, `(* a b …)`, `(/ a b …)` | Arithmetic |
| `(= a b …)`, `(< a b …)`, `(<= a b …)`, `(> a b …)`, `(>= a b …)` | Compare adjacent numbers |
| `(and a b …)`, `(or a b …)`, `(not a)` | Short-circuit Boolean logic |
| `(list a b …)` | Build a list |
| `(length lst)`, `(empty? lst)` | Item count, emptiness test |
| `(list-ref lst index)`, `(first lst)`, `(last lst)` | Read an item (0-based) |
| `(dict key value …)` | Build a dictionary from alternating keys and values |
| `(dict-ref d key)`, `(dict-set d key value)` | Read one value; answer a new dictionary |
| `(dict-keys d)`, `(dict-values d)` | Read all keys or values as a list |
| `(string-append text …)`, `(number->text n)` | Concatenate; convert |
| `(split-lines t)`, `(split-whitespace t)`, `(split-text t "sep")` | Split text into a list |
| `(choose-from-list lst "prompt")` | Ask the user to choose one item |
| `(ask-text "prompt")`, `(ask-number "prompt")` | Ask for typed input |
| `(format-current-date "format")` | Format the current date as text |
| `(show-result value)` | Show and return a value when used last |
| `(notification "message")`, `(open-url "https://…")`, `(wait 1.5)` | Effects |

Booleans are `#t` and `#f`. Strings support `\n`, `\r`, `\t`, `\"`, and `\\`.
Comparisons test adjacent pairs, so `(< 1 2 3)` means `1 < 2` and `2 < 3`.

### Types

Types are inferred from use — no annotations. In `(define (double v) (+ v v))`,
`v` and the result are numbers. Unconstrained values stay generic and preserve
their runtime Shortcut value. Reading a list element or dictionary value yields
a generic value, so whatever consumes it decides its type. The compiler reports
provable conflicts; genuinely dynamic mismatches surface at runtime.

### Function calls

Calls compile to Dictionary + Run Shortcut actions, passing arguments by
parameter name. Every referenced function must be installed under its generated
name — replace an existing Shortcut rather than importing a duplicate, since an
automatic `sum-to 1` suffix breaks name-based calls.

### Recursion

Direct and mutual recursion both work; a terminating condition is required.

A function whose entire body is one direct self-call in tail position (like
`sum-to` above) compiles to a bounded in-workflow loop instead of a recursive
Shortcut call, so it costs no Shortcut call-stack depth and stops as soon as a
base case is reached. The loop is capped at 2000 iterations as a safety net;
past that it returns whatever the accumulator held.

Everything else — mutual recursion, non-tail self-calls, multi-form bodies, and
any side effect on the path to the self-call — recurses through Run Shortcut and
stays bounded by the Shortcuts runtime call stack.

## Sharp edges

- **Lists cannot nest.** A list element may not be a list or a dictionary.
  Dictionaries *can* nest, except via `dict-set`, whose value rides in a
  text-shaped field — build nested records with `dict`.
- **`.` in a dictionary key is a path.** `(dict-ref d "a.b")` looks for `b`
  inside `a`, not for a key named `a.b`.
- **Some arguments must be literals**: `split-text` separators, all prompts, and
  `format-current-date` patterns.
- **Not yet implemented**: `cons`/`append`/`map`/`filter`, `dict-has-key?`,
  dictionary removal, higher-order functions, macros, general date values.

## CLI

```text
longway build <file.longway> [-o directory] [--xml] [--actions catalog.json]…
                             [--sign[=anyone|people-who-know-me]]
longway check <file.longway> [--actions catalog.json]…
longway inspect-actions <file.shortcut> [-o directory] [--third-party-only]
longway version
```

- `check` validates without writing files; `build` emits one `.shortcut` per function.
- `--xml` emits readable XML property lists instead of binary.
- `--sign` runs `/usr/bin/shortcuts sign` on every artifact, defaulting to
  `people-who-know-me`. The whole program is signed before any file is replaced.
- `inspect-actions` lists actions from an unsigned workflow or an Apple-signed
  export, optionally writing each as an XML plist. Signed exports are verified
  against the public key in their certificate and unpacked with `aea`/`aa`. The
  output directory must be empty, and extracted parameters can contain private
  workflow data — review before sharing.

## Action catalogs

Third-party app actions are data, not compiler code. Pass versioned JSON
catalogs explicitly:

```sh
.build/release/longway check Examples/working-copy.longway \
  --actions Actions/WorkingCopy.longway-actions.json
```

Each entry gives a source name, typed arguments, an optional result, a
side-effect flag, and a raw action template. Constant fields are copied as-is;
`$longway` placeholders are rendered during compilation:

```json
{
  "version": 1,
  "actions": [{
    "name": "example-echo",
    "arguments": [{ "name": "text", "type": "text" }],
    "result": { "type": "text", "outputName": "Echo", "runtimeTyped": true },
    "sideEffect": false,
    "template": {
      "WFWorkflowActionIdentifier": "com.example.EchoIntent",
      "WFWorkflowActionParameters": {
        "UUID": { "$longway": "uuid" },
        "text": { "$longway": "argument", "name": "text", "encoding": "text-token" }
      }
    }
  }]
}
```

Argument types are `text`, `number`, `boolean`, `list`, `dictionary`, and `any`.
Encodings are `text-token` (literal or output reference), `attachment`
(materializing literals first), `literal` (rejects computed values), `number`,
and `app-entity`. Catalog names may not shadow built-ins, functions, or another
catalog; every argument must be used by its template; templates must generate
their own UUID; declared side effects disable tail-call optimization.

`Actions/WorkingCopy.longway-actions.json` is a worked example derived from an
exported iOS workflow. Its output is structurally verified, but the parameterized
repository fields still need a device test with Working Copy installed.

## Project layout

- `Sources/LongwayCore` — lexer, parser, inference, and Shortcut emitter
- `Sources/LongwayCLI` — dependency-free CLI and Apple signer integration
- `Tests/LongwayCoreTests`, `Examples/` — tests and sample programs

Compilation runs source → tokens → syntax → definitions → inferred signatures →
Shortcut actions. `Builtins.swift` declares every built-in form's arity and
operand types once; inference checks against that table and the reserved-name set
derives from it, so adding a form means one table entry plus its lowering.
