# Nimony LSP

Build with `bin/nimony c -o:bin/nimony-lsp src/lsp/server.nim`, then launch
`bin/nimony-lsp` over stdio. The server implements JSON-RPC framing and LSP
initialize/shutdown, full document synchronization, diagnostics, completion,
hover, and go-to-definition.

The document database stores syntax-token nodes with source ranges and lexical
scope identities. For identifier queries, the server invokes `nimony check`
with `--visible`; phase 3 captures the `SemContext` scope-chain results and
resolved name candidates. The query path retains `ErrT` nodes and returns its
snapshot rather than failing on semantic errors elsewhere in the module.
An edit reparses and rechecks its containing document, while individual syntax
nodes remain the database records. This is an explicit boundary: Nimony's
existing incremental build graph does not provide node-granular semantic
invalidation. LSP parser, dependency, and semantic artifacts live only below
`nimcache/lsp/`; batch compilation never reads them.

## Document mode: one compile per edit

`nimony check --visible:FILE,0,0` runs in *document mode*. Line 0 is not a
source line, so instead of matching one cursor it records, in a single sem pass:

- every identifier occurrence in the file and what it resolved to
  (`position` rows, each followed by its own `candidate` rows),
- the module's import table (`import` rows), which does not depend on a cursor,
- the semantic errors (`error` rows).

The editor indexes the occurrences by position, so hover and go-to-definition
are table lookups. Measured over stdio on a document importing five stdlib
modules (Termux, 8 cores):

| operation | before | after |
| --- | --- | --- |
| open, empty `nimcache/lsp/` | ~2.4 s | ~2.7 s |
| hover, first time | ~100 ms | ~1 ms |
| hover, cursor moved away and back | ~100 ms | ~0 ms |
| `didChange` | ~100 ms per query | ~400 ms once |

The cost moved to the edit, which is where it belongs: it is paid once per
version instead of once per cursor move. The cold case got slightly slower
because one pass now records every occurrence rather than one.

Completion in document mode offers the recorded import table plus the names the
lexical index finds in the local scope chain. It does not see module-level
symbols declared in *other* files (that is what the import table is), and a name
declared later in the file is offered the same way the lexical index offers it.
The cursor-specific `--visible:FILE,LINE,COL` mode still exists and still
returns the full scope chain at that position; `ideQueryAt` falls back to it when
a snapshot has no positions.

Coverage is measured by asking hover at every identifier token of a file,
skipping comments and string literals. On this branch, measured on a *cold*
`nimcache/lsp` with nothing pre-built, `src/lsp/handlers.nim` answers 743 of 778
(95.5%), `src/lsp/server.nim` 90 of 101 (89.1%) and `src/lsp/database.nim` 2181
of 2280 (95.7%). The cold build matters: an earlier measurement of 87.9% was
taken with the cache already warm, which silently pre-seeded the very dependency
the cold path needs and made a broken configuration look like a coverage gap.

Most of what does not answer is the module path in an `import` list and a pragma
name -- neither is an identifier in the checked tree, and together they account
for every miss in `server.nim`. What is left is a real gap: a `proc`'s declared
return type is not recorded (`proc quoteJson(s: string): string` answers for
`s` but not for the result type), and the magic `result` is not. Every other
real occurrence -- a parameter in a signature, a field chosen through a dot, a
name imported from another module, a local shadowed in an inner scope -- is
recorded.

Two details make that work. The walk reads the finished phase-3 tree rather
than a resolution callback, so it sees occurrences wherever the tree puts them.
And NIF line info for a `dot` expression's field points at the operator rather
than at the name (`node.c` records the column of the `e` ending `node`), so each
recorded column is snapped to the name on its line once, when the sidecar is
parsed, rather than on every query.

The root module is handed to sem as an already-parsed `.nif`, which is what
makes the editor's fault-tolerant parse possible: `execNifler` returns
immediately for a `.nif`, so the buffer is parsed by the recovering parser in
this process and never re-parsed by the fail-fast one. The price is that the
root's directory becomes the cache directory rather than the source tree, and a
`./`-less sibling import is resolved against the importing file's own directory.
So `src/lsp/handlers.nim`'s `import database` had nowhere to resolve to: nimony
created the node with no parse rule and the build died with `cannot open:
<mod>.s.nif`. The open document's directory therefore goes on the search path in
`runCompiler`, and the LSP no longer asserts anything about the dependency graph
-- nimony parses the dependencies and applies its own mtime and `OnlyIfChanged`
rules, which is also why the result cannot go stale underneath the editor.

A failed compile must never look like a clean one. `execCmdEx` reports failure
through its exit code and does not raise, so `runCompiler` logs the compiler's
own first error line to stderr and reports the failure as a diagnostic. Without
that, a build that died produced an empty sidecar, which the server published as
"no errors" and answered every query from -- the file simply stopped working for
reasons the user cannot see.

The remaining cost is the subprocess itself: one `nimony check` per document
version, re-resolving the document and its import graph. That is the bridge
described above, and removing it means keeping a warm `SemContext` per open
document inside the server process, which needs an audit of what `nimsem` assumes
is single-process, short-lived global state (symbol pools, interning tables), in
the same spirit as the parallel-compiler audit.

Parser recovery is a safe in-place extension because it preserves the grammar's
ordinary FIRST/FOLLOW analysis and emits balanced `(err ...)` nodes only when
the parser is explicitly placed in recovery mode. Batch parsing keeps its
existing fail-fast behavior. By contrast, type-tolerant overload resolution
changes a point-match query into a set-of-compatible-candidates query; Phase
2v1 deliberately does not modify `sigmatch`. Unresolved or type-dependent
completion sites return no result rather than a guessed answer. Signature help
and best-effort resolution of unknown argument types remain a separate future
design phase and should be evaluated after editing-session experience.

The lexical index remains a fallback for positions without a semantic identifier
node, such as a blank completion line. Semantic name lookup tolerates unrelated
parser and type errors by returning the cursor's phase-3 scope snapshot without
running `sigmatch`. Type-dependent member/call results remain empty when they
cannot be established without inference.

## Diagnostics

An editor cannot read the reporter's stdout, so the same `--visible` run that
answers a query also writes the module's semantic errors into the
`<module>.ide.tsv` sidecar as `error<TAB>file<TAB>line<TAB>col<TAB>message` rows.
`reporters.collectErrors` is the collecting twin of `reportErrors`: same walk,
same source dedup, same set of diagnostic `(err ...)` nodes, but the records are
returned instead of printed.

A document is sem-checked on open and on every change with the track line set to
`0`, which is not a source line: it collects the errors of the whole document
and matches no name. One compile therefore serves both the diagnostics and a
later query. Parser and semantic diagnostics are published together.

## Hover documentation

The parser records every `##` block, keyed by the line the block ends on. A
declaration is documented by the block that *follows* it, because that is where
a Nim doc comment goes: inline at the end of the declaration, or as the first
statement of its body. A `##` run *above* a declaration documents nothing, so the
block is looked for below it and never above. The lexer has already merged
consecutive `##` lines into one token and stripped their indentation, which is
why a two-paragraph block, a `##[` run and a list inside a comment all come out
as the author wrote them without this side having to know about any of those
shapes. A `#` comment is not a doc comment: the lexer never makes it a token, so
it cannot be mistaken for one.

Recording is opt-in (`Parser.keepComments`) and only the editor sets it. The
grammar's `comment[ COMMENT ]` slot looks like the place for the text and is not:
`commentStmt` is wired only into the statement lists that name it, so a `##`
inside an object body reaches `emitLeaf` with no wrapper at all, and emitting a
string there leaves a bare literal between the fields, which sem reports as
ill-formed. Keeping the text out of the tree entirely leaves the written NIF
byte-identical and no consumer able to notice.

Imported symbols are still read from the file on disk with a line scan, because
the tree only holds the open document. That is where the remaining weakness is:
it cannot see a `##[` block, and it shows a stale copy for another file that is
open but unsaved. Carrying comments through sem would fix both, and NIF already
has the transport for it -- `NifLineInfo.comment` rides along as a `#...#`
decoration and `nifbuilder.attachComment` writes it -- but sem propagates it in
exactly one place today (`templates.nim`), so nothing has ever round-tripped it.
