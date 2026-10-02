# Nimony LSP

Build with `bin/nimony c -o:bin/nimony-lsp src/lsp/server.nim`, then launch
`bin/nimony-lsp` over stdio. The server implements JSON-RPC framing and LSP
initialize/shutdown, full document synchronization, diagnostics, completion,
hover, and go-to-definition.

The document database stores syntax-token nodes with source ranges and lexical
scope identities. For identifier queries, the server invokes `nimony check`
with `--visible`; phase 3 captures the active `SemContext` scope-chain results
and resolved name candidates. The query path retains `ErrT` nodes and returns
its snapshot rather than failing on semantic errors elsewhere in the module.
An edit reparses and rechecks its containing document, while individual syntax
nodes remain the database records. This is an explicit boundary: Nimony's
existing incremental build graph does not provide node-granular semantic
invalidation. LSP parser, dependency, and semantic artifacts live only below
`nimcache/lsp/`; batch compilation never reads them.

## Known limitation: one compiler process per query

Queries shell out. Every hover, definition or completion request spawns
`nimony check`, which re-resolves the document and its whole import graph. The
cache holds exactly one `(line, character)`, so only an *immediately* repeated
position is free: moving away and back costs another process. Measured over
stdio on a document importing five stdlib modules (Termux, 8 cores):

| operation | cost |
| --- | --- |
| first query, empty `nimcache/lsp/` | ~2.4 s |
| query at a cursor position not cached | ~100 ms |
| query repeated at the cached position | ~0 ms |

The ~100 ms is the build graph reusing already-parsed and already-semmed
`.s.nif` artifacts for the imports; it is not a cheap query. Moving the cursor
one line re-resolves the document's own scopes from zero, and a larger import
graph makes the cold case worse. An editor that re-queries on every keystroke
and mouse move will feel this.

This is a bridge transport, not a steady-state design. It exists because it
proves the `--visible` flag and the TSV wire format are semantically correct.
Replacing it means keeping a warm `SemContext` per open document inside the
server process and re-running only on text change, which needs an audit of what
`nimsem` assumes is single-process, short-lived global state (symbol pools,
interning tables), in the same spirit as the parallel-compiler audit. Until that
lands, per-query process spawn is the expected price of a semantic answer.

`tests/lsp/queries.nim` exercises this path. Note that the in-process timings it
prints are not trustworthy on every platform — `getMonoTime` does not advance
reliably here — so measure latency from outside the process.

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
