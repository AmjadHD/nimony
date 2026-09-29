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
