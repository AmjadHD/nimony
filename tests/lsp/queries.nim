## Query latency against a document with a real import graph. The tiny
## fixtures elsewhere cannot show the subprocess cost, because they never
## resolve more than a handful of modules.

import std / [monotimes, os, strutils, syncio, times]
import ../../src/lsp/[database, handlers]

const Queries = 5

proc report(line: string) =
  stdout.write line
  stdout.write "\n"
  stdout.flushFile()

proc elapsedMs(start: MonoTime): float64 =
  (getMonoTime() - start).inNanoseconds.float64 / 1_000_000.0

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
  var start = getMonoTime()
  openOnce(db, uri, source)
  report "open (parse + sem + diagnostics): " & $elapsedMs(start)

  # The point of the measurement: a cursor move re-checks the module and its
  # whole import graph from scratch, so every cold position costs a fresh
  # compile and only an exactly repeated position is free.
  for i in 0 ..< Queries:
    let line = 24 + i
    start = getMonoTime()
    discard hoverAt(db, uri, line, 6)
    report "hover cold at line " & $line & ": " & $elapsedMs(start)

  start = getMonoTime()
  discard hoverAt(db, uri, 24, 6)
  report "hover repeated at one position: " & $elapsedMs(start)

  start = getMonoTime()
  openOnce(db, uri, source)
  report "reopen (unchanged text): " & $elapsedMs(start)

  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":\"""" &
    escapeJson(uri) & """"}}}""")

proc runBench() =
  try:
    bench()
  except:
    report "bench failed"

runBench()