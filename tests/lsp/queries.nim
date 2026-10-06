## Queries against a document with a real import graph. The tiny fixtures
## elsewhere cannot exercise that, because they never resolve more than a handful
## of modules -- an import-heavy document is where a query is most likely to take
## the slow path.

import std / [assertions, os, strutils, syncio]
import ../../src/lsp/[database, handlers]

const Queries = 5

proc escapeJson(s: string): string =
  ## The document text is the only field needing escaping; the framing quotes
  ## are plain quotes inside a Nim triple-quoted string.
  s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\t", "\\t")

proc openOnce(db: var Database; uri, text: string) {.raises.} =
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":\"""" &
    escapeJson(uri) & """","languageId":"nim","version":1,"text":\"""" &
    escapeJson(text) & """"}}}""")

proc hoverAt(db: var Database; uri: string; line, character: int): string {.raises.} =
  let pos = """{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":\"""" &
    escapeJson(uri) & """"},"position":{"line":""" & $line & ""","character":""" &
    $character & """}}}"""
  handle(db, pos).response

proc bench() {.raises.} =
  var db = initDatabase(getCurrentDir())
  let uri = "file:///workspace/lsp-bench.nim"
  let source = """
import std/[strutils, tables, sets, os, sequtils, algorithm, json, options]
import std/strformat

## Doc for `total`.
proc total(xs: seq[int]): int =
  ## Sums the sequence.
  result = 0
  for x in xs: result += x

type Config* = object
  name*: string
  count*: int

proc render(c: Config): string =
  let parts = @[c.name, $c.count]
  parts.join(",")

proc work() =
  let t = toTable([1, 2, 3], [4, 5, 6])
  let s = initHashSet[int]()
  s.incl 1
  let doubled = toSeq(@[1, 2]).mapIt(it * 2)
  let name = "n" & $doubled.len
  var cfg = Config(name: name & fmt"x", count: t.len)
  discard render(cfg)
  discard total(@[1, 2, 3])
  let sorted = sorted([3, 1, 2])
  discard sorted[0]
  let parsed = toTable(1, 2)
  discard parsed.len
"""
  # These queries are the point of the test, not a measurement: what matters is
  # that each answers from the right occurrence and that no query recompiles.
  #
  # Nothing here prints. `tests/lsp` is a joined group and is expected to be
  # silent, and a timing could not be a golden even if it were -- so these lines
  # used to drop the whole group out of the joined program and the harness quietly
  # fell back to running the tests one at a time. The numbers they reported are
  # recorded in the commit messages instead: 64ms -> 0.05ms for a document with no
  # recorded occurrences (a32a248e), and the per-position cost in a32a248e's
  # message.
  openOnce(db, uri, source)
  for i in 0 ..< Queries:
    discard hoverAt(db, uri, 24 + i, 6)
  discard hoverAt(db, uri, 24, 6)
  openOnce(db, uri, source)

  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":\"""" &
    escapeJson(uri) & """"}}}""")

proc runBench() =
  # A raise here used to be reported and swallowed, so the test passed with the
  # queries never having run. It has to fail the test.
  try:
    bench()
  except:
    assert false, "lsp queries raised unexpectedly"

runBench()