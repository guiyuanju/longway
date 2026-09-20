# Longway

Longway is a small, Scheme-inspired language that compiles functions into Apple Shortcut files. The compiler and CLI are written in Swift.

This repository is an MVP: it provides readable S-expressions, source-located diagnostics, type inference, binary/XML property-list generation, and optional signing through Apple's `shortcuts` CLI. It is not a complete Scheme implementation.

## Quick start

Longway requires macOS 13+ and Swift 6.

```sh
swift build -c release
.build/release/longway check Examples/functions.longway
.build/release/longway build Examples/functions.longway
```

A source file may define several functions. Build writes one standalone Shortcut per function to `<source-name>.shortcuts/` by default:

```text
Examples/functions.shortcuts/
├── sum-to.shortcut
└── sum-to-ten.shortcut
```

Unsigned output is useful for inspecting compiler output:

```sh
plutil -p Examples/functions.shortcuts/sum-to.shortcut
```

To produce files that Apple's Shortcuts app can import, sign every generated function:

```sh
.build/release/longway build Examples/functions.longway \
  -o Functions --sign
open Functions/sum-to.shortcut
open Functions/sum-to-ten.shortcut
```

Signing is an Apple service. It may require an Apple ID, network access, and permission to share shortcuts. Longway signs the complete program before replacing any destination files.

## Functions

Programs contain one or more `define` forms. Parameters and return values do not need type annotations:

```scheme
(define (add x y)
  (+ x y))

(define (main)
  (add 20 22))
```

Each definition becomes an independently importable Shortcut named after the function. A function's final expression is its return value. Earlier forms may perform actions for side effects:

```scheme
(define (morning)
  (notification "Good morning!")
  (wait 1)
  "Morning complete")
```

Function calls compile to explicit Dictionary and Run Shortcut actions. Arguments are transported by parameter name. The called Shortcut reads them from `Shortcut Input` and ends with Stop and Output.

When invoking a generated function from outside Longway, pass a dictionary whose keys match its parameter names. All function Shortcuts referenced by a program must be installed without renaming them. Replace an existing generated Shortcut instead of importing a duplicate: an automatic suffix such as `sum-to 1` breaks name-based calls.

### Inference and generic values

Longway infers constraints from operations. In this function, `value` and the result are inferred as numbers:

```scheme
(define (double value)
  (+ value value))
```

Values without constraints remain generic and preserve their runtime Shortcut value:

```scheme
(define (identity value)
  value)
```

The compiler reports provable type conflicts, while genuinely dynamic mismatches may be reported by Shortcuts at runtime.

### Recursion

Direct and mutual recursion are supported. Recursive calls run the generated Shortcut again, so a terminating condition is required:

```scheme
(define (sum-to n acc)
  (if (= n 0)
      acc
      (sum-to (- n 1) (+ acc n))))

(define (sum-to-ten)
  (sum-to 10 0))
```

`if`, `and`, and `or` keep non-selected expressions inside Shortcut conditional branches, preserving lazy and short-circuit behavior.

A function whose entire body is a single direct self-call in tail position — like `sum-to` above, where every branch of the closing `if` either returns a plain value or calls `sum-to` again with no further work — compiles to a bounded loop inside the same Shortcut instead of a recursive Shortcut call, so it no longer consumes Shortcut runtime call-stack depth. As soon as a base case is reached, the loop stops the whole Shortcut immediately instead of continuing to iterate, so ordinary terminating recursion runs in exactly as many steps as it needs. The loop is still capped at a fixed number of iterations (currently 2000) as a safety net for recursion that never reaches a base case; in that pathological case it returns whatever the accumulator held at the bound instead of running forever. Mutual recursion (like `even`/`odd` calling each other), non-tail recursion (a self-call used inside another expression, e.g. `(+ 1 (count-up (- n 1)))`), and any function whose body has more than one form or performs a `notification`/`open-url`/`wait`/`show-result` on the path to its self-call are not loop-optimized — they keep calling the generated Shortcut recursively and are still bounded by Shortcut runtime call-stack depth.

## Lists

`(list ...)` builds a Shortcuts list. Elements are ordered and untyped — a list may mix text, numbers, and Booleans — and indexes start at 0 like Scheme's `list-ref`:

```scheme
(define (second-name)
  (let ((names (list "Ada" "Grace" "Alan")))
    (list-ref names 1)))
```

`length` counts items, `first` and `last` read the ends, `empty?` tests for no items, and `list-ref` reads by index. Reading an element yields a generic value, so the operation that consumes it decides its type:

```scheme
(define (sum-list items index total)
  (if (= index (length items))
      total
      (sum-list items (+ index 1) (+ total (list-ref items index)))))
```

That traversal is a single-form tail-recursive definition, so it compiles to one bounded in-workflow loop: the list stays in a Shortcuts variable and is never re-serialized between iterations.

A list may be passed to another Longway function and returned from one. An argument travels as an array-typed field in the argument dictionary, which preserves it; a result returns through Stop and Output as a single attachment, the same way the Shortcuts editor writes a list variable.

Lists also cannot nest — a list element may not itself be a list or a dictionary — and there is no `cons`, `append`, `map`, or `filter` yet.

## Dictionaries

`(dict ...)` builds a Shortcuts dictionary from alternating keys and values. Keys are text; values are untyped, just like list elements:

```scheme
(define (greeting)
  (let ((person (dict "name" "Ada" "born" 1815)))
    (dict-ref person "name")))
```

`dict-ref` reads one value, `dict-keys` and `dict-values` read all of them out as lists, and `dict-set` answers a new dictionary rather than changing the one it was given:

```scheme
(define (renamed)
  (let ((person (dict "name" "Ada")))
    (dict-ref (dict-set person "name" "Grace") "name")))
```

Because a read is untyped, the operation consuming it decides its type — `(- year (dict-ref person "born"))` reads `born` as a number.

Unlike a list, a dictionary may hold a list or another dictionary, so records can nest:

```scheme
(define (record)
  (dict "name" "Ada" "languages" (list "Analytical Engine")))
```

The one exception is `dict-set`, which cannot store a list or a dictionary; build those with `dict`.

Dictionaries cross function calls in both directions, as arguments and as return values.

Two sharp edges. Shortcuts treats `.` in a key as a path into nested content, so `(dict-ref d "a.b")` looks for `b` inside `a` rather than for a key literally named `a.b`. And there is no `dict-has-key?` yet — Shortcuts has no key-membership action, and the available workarounds are not safe to rely on until `dict-set`'s copy-versus-mutate behavior is confirmed on a device.

## Text and interactive input

`string-append` combines text values into one Shortcuts Text action. Convert a number explicitly with `number->text`:

```scheme
(define (receipt name amount)
  (string-append "Paid " (number->text amount) " to " name))
```

`split-lines`, `split-whitespace`, and `split-text` answer lists that work with the ordinary list accessors. A custom separator is currently a string literal:

```scheme
(first (split-text "name | account" " | "))
```

Interactive functions can ask for typed input or let the user choose an item:

```scheme
(choose-from-list options "Choose an account")
(ask-text "Description")
(ask-number "Amount")
```

`format-current-date` formats the current date with a literal Unicode date-format pattern:

```scheme
(format-current-date "yyyy-MM-dd")
```

Prompts and date formats are literals in the current MVP. See `Examples/transaction.longway` for a complete interactive Beancount transaction builder.

## Expressions and actions

Bindings are lexically scoped. A `let` initializer sees the outer scope rather than sibling bindings. Use `let*` when each initializer should see the bindings before it:

```scheme
(define (calculate)
  (let* ((x 10)
         (y (+ x 4)))
    (* y 2)))
```

A later `let*` binding may reuse a name to sequentially shadow its earlier value. Ordinary `let` continues to reject duplicate names in one binding list.

Numeric comparisons accept at least two operands. Variadic comparisons test adjacent pairs, so `(< 1 2 3)` means both `1 < 2` and `2 < 3`.

| Longway form | Meaning |
| --- | --- |
| `(define (name args …) body … result)` | Compile one standalone function Shortcut |
| `(name args …)` | Call another generated function Shortcut |
| `(let ((name value) …) body …)` | Lexically bind values with parallel initializer scope |
| `(let* ((name value) …) body …)` | Lexically bind values sequentially from left to right |
| `(+ a b …)`, `(- a b …)` | Add or subtract numbers |
| `(* a b …)`, `(/ a b …)` | Multiply or divide numbers |
| `(= a b …)`, `(< a b …)`, `(<= a b …)`, `(> a b …)`, `(>= a b …)` | Compare adjacent numbers |
| `(if condition consequent alternative)` | Lazily select a value or action branch |
| `(and a b …)`, `(or a b …)` | Short-circuit Boolean operations |
| `(not value)` | Boolean negation |
| `(list a b …)` | Build a list |
| `(length lst)` | Number of items |
| `(list-ref lst index)` | Read an item by 0-based index |
| `(first lst)`, `(last lst)` | Read the first or last item |
| `(empty? lst)` | Test for a list with no items |
| `(dict key value …)` | Build a dictionary from alternating keys and values |
| `(dict-ref d key)` | Read one value by key |
| `(dict-set d key value)` | Answer a new dictionary with `key` set |
| `(dict-keys d)`, `(dict-values d)` | Read all keys or all values as a list |
| `(string-append text …)` | Concatenate text values |
| `(number->text number)` | Convert a number to text |
| `(split-lines text)`, `(split-whitespace text)` | Split text into a list |
| `(split-text text "separator")` | Split text with a literal separator |
| `(choose-from-list list "prompt")` | Ask the user to choose one item |
| `(ask-text "prompt")`, `(ask-number "prompt")` | Ask for typed input |
| `(format-current-date "format")` | Format the current date as text |
| `(show-result value)` | Show and return a value when used last |
| `(notification "message")` | Show Notification |
| `(open-url "https://…")` | URL, then Open URLs |
| `(wait 1.5)` | Wait |

Strings support `\n`, `\r`, `\t`, `\"`, and `\\`. Booleans are written as `#t` and `#f`.

## CLI

```text
longway build <file.longway> [-o output-directory] [--xml]
              [--sign[=anyone|people-who-know-me]]
longway check <file.longway>
longway version
```

- `build` emits one `.shortcut` per function.
- `check` validates every definition without writing files.
- `-o` selects the output directory.
- `--xml` emits human-readable XML property lists instead of binary files.
- `--sign` invokes `/usr/bin/shortcuts sign` for every artifact. It defaults to `people-who-know-me`; use `--sign=anyone` for public sharing.

## Project layout

- `Sources/LongwayCore` — lexer, parser, inference, semantic validation, and Shortcut emitter
- `Sources/LongwayCLI` — dependency-free command-line interface and Apple signer integration
- `Tests/LongwayCoreTests` — parser/compiler tests
- `Examples` — sample Longway programs

## MVP boundaries

Longway currently supports first-order functions, recursive calls, lexical bindings, strings, numbers, Booleans, flat lists, dictionaries, arithmetic, comparisons, logical expressions, typed conditionals, text splitting and composition, typed prompts, list selection, current-date formatting, and a small action catalog. Functions are linked by installed Shortcut name. Tail-call optimization covers only direct, single-form, side-effect-free self-recursion (see Recursion above); mutual recursion, non-tail recursion, higher-order functions, macros, general date values, list construction beyond `list` (`cons`, `append`, `map`, `filter`), nested lists, `dict-has-key?` and dictionary removal, and a larger action catalog remain future work.
