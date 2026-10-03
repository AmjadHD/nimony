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
skipping comments and string literals. On this branch, `src/lsp/handlers.nim`
answers 745 of 848 (87.9%) and `src/lsp/server.nim` 90 of 101 (89.1%). What
does not answer is the module path in an `import` list and a pragma name --
neither is an identifier in the checked tree. Every real occurrence -- a
parameter in a signature, a field chosen through a dot, a name imported from
another module, a local shadowed in an inner scope -- is recorded.

Two details make that work. The walk reads the finished phase-3 tree rather
than a resolution callback, so it sees occurrences wherever the tree puts them.
And NIF line info for a `dot` expression's field points at the operator rather
than at the name (`node.c` records the column of the `e` ending `node`), so each
recorded column is snapped to the name on its line once, when the sidecar is
parsed, rather than on every query.

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

NIF carries no comments -- the parser discards them -- so hover reads the `##`
block directly above a declaration back from the source text, stopping at the
first line that is not a doc comment. That scan runs against the editor's own
buffer for the open document and against the file on disk for imported symbols.
