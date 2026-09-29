# Nimony LSP

Build with `bin/nimony c -o:bin/nimony-lsp src/lsp/server.nim`, then launch
`bin/nimony-lsp` over stdio. The server implements JSON-RPC framing and LSP
initialize/shutdown, full document synchronization, diagnostics, completion,
hover, and go-to-definition.

The document database stores syntax-token nodes with source ranges and lexical
scope identities. An edit currently reparses and reindexes its containing
document; the semantic name index is therefore module-granular in this first
shippable version. This is an explicit boundary: node-granular semantic cache
invalidation is not provided by Nimony's existing incremental build graph.
LSP parse snapshots are written only below `nimcache/lsp/`; batch compilation
does not read that namespace, and LSP does not trust batch cache artifacts.

Parser recovery is a safe in-place extension because it preserves the grammar's
ordinary FIRST/FOLLOW analysis and emits balanced `(err ...)` nodes only when
the parser is explicitly placed in recovery mode. Batch parsing keeps its
existing fail-fast behavior. By contrast, type-tolerant overload resolution
changes a point-match query into a set-of-compatible-candidates query; Phase
2v1 deliberately does not modify `sigmatch`. Unresolved or type-dependent
completion sites return no result rather than a guessed answer. Signature help
and best-effort resolution of unknown argument types remain a separate future
design phase and should be evaluated after editing-session experience.

The current editor-side declaration index is lexical and document-local. It
provides useful navigation and scope completions across unrelated parser
errors, while the semantic API `visibleDeclarationAtCursor` exposes Nimony's
existing scope-chain lookup for use by semantic-walker integrations.
