# 1. A real Clojure reader, once caching pays for it

Status: proposed

## Context

Cljbang reads Clojure with the Emacs Lisp reader. That reader is written
in C and is very fast, and it happens to accept most Clojure surface
syntax, so it was the obvious choice. Everything the elisp reader gets
wrong is then patched up afterwards:

- `{...}` survives as symbols glued to their neighbours, `{:a` and `1}`,
  and a splicing pass reassembles the map literals
- `#{` and `#(` are read errors, so the source text is rewritten to a
  marker before reading
- commas read as unquote and are spliced back out as whitespace

Syntax quote is where this stops working. The elisp reader has its own
idea of every part of it:

| written | what the reader does |
|---|---|
| `` `(+ 1 2) `` | elisp backquote, which happens to fit |
| `` `(+ ,x 1) `` | the unquote is stripped by the comma pass, silently |
| `~x` | a symbol named `~x` |
| `~@xs` | a symbol named `~@xs` |
| `x#` | reads as `x`, so an auto-gensym collides instead of being unique |

So macros have to build their expansion with `list` and `cons`, and a
backquote that looks like it interpolates quietly does not.

The reason not to write a Clojure reader was cost. Reading is on the path
of every load. When cljbang still used parseclj, parsing 1000 defns took
about 33ms against about 5ms for the elisp reader plus the rewriting
passes.

Caching changes that. Compiled output is now written to a `.elc` keyed on
the Emacs and cljbang versions, so reading and compiling happen once per
edit rather than once per startup. A warm load is about 1.9ms and does no
reading at all. Thirty milliseconds on a cold load is no longer the
number that matters.

## Decision

Write a Clojure reader for cljbang and use it for `.clj` files, once
there is reason to want syntax quote badly enough. It would produce the
elisp shapes the compiler already expects, so the compiler is unaffected.

That would let us delete the two workarounds that exist only because of
the elisp reader: `cljbang--rewrite-dispatch` and the brace splicing.

## Consequences

Gained: syntax quote with real unquote and auto-gensym, so macros can be
written the way they are in Clojure. `#{}` and `#()` stop needing a text
rewrite. Metadata, ratios and character literals become possible.

Lost: `clj!` cannot use it. The elisp reader runs before any macro, so
forms inside `clj!` are read before cljbang sees them. `clj!` would stay
on the elisp reader and its current limitations, which brings back the
two-tier split that dropping parseclj removed. Either accept that, or
give `clj!` a string form so it has text to read.

Also lost: the elisp reader is C and free. A reader in elisp is neither.
The cache makes that affordable rather than free, and a cold load gets
slower.

Open: whether the reader is new code or a revived parseclj, and whether
`clj!` follows or stays behind.
