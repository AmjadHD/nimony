## What an editing session actually costs: ONE document, many `didChange`.
##
## The handler suite opens a dozen documents and asks about each once, so almost
## every check it makes is a FIRST check -- and a first check has to go through
## the subprocess, because that run is what builds the dependency closure the
## in-process path reads. That made the suite report the in-process path as worth
## nothing, which is a true statement about the suite and a false one about an
## editor.
##
## This is the shape the editor is actually in: open a file, type, type, type.
## The first keystroke pays for the closure and every one after it should not.
## So it reports per-keystroke cost after the first, which is the number a person
## feels, and it reports the first separately rather than averaging it away.

## NOT a suite test: it prints measurements and takes a minute, and a test whose
## pass/fail is a stopwatch is a test that fails on a busy machine. Run it by hand:
##   nim c -r -o:bin/typing tests/lsp/typing.nim && ./bin/typing
## `hastur` will still run it, so it opts out of the joined group.

import std / [assertions, os, strutils, syncio, uri, envvars, times, algorithm]
import ../../src/lsp / [database, handlers]

proc jsonEscape(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add ch

proc document(keystrokes, decls: int): string =
  result = ""
  ## A source file with the shape that makes sem do real work: imports, types,
  ## overloads, and procs whose bodies call them. Big enough that a compile is
  ## not dominated by process startup, small enough to type into repeatedly.
  result = "import std/[strutils, tables]\n\n"
  for i in 0 ..< decls:
    result.add "type Rec" & $i & "* = object\n"
    result.add "  name*: string\n"
    result.add "  count*: int\n"
    result.add "  tags*: seq[string]\n\n"
    result.add "proc pick" & $i & "*(a: int): string =\n"
    result.add "  ## Doubles a.\n"
    result.add "  $a * 2\n\n"
    result.add "proc pick" & $i & "*(a: string): string =\n"
    result.add "  ## Repeats a.\n"
    result.add "  a & a\n\n"
    result.add "proc use" & $i & "*(r: Rec" & $i & "; s: string): string =\n"
    result.add "  discard pick" & $i & "(r.count)\n"
    result.add "  discard pick" & $i & "(s)\n"
    result.add "  r.name.toUpperAscii & \" \" & r.tags.join(\",\")\n\n"
  for k in 0 ..< keystrokes:
    result.add "# edit " & $k & "\n"

proc request(methodName, uriText, text: string; id = -1): string =
  result = "{\"jsonrpc\":\"2.0\""
  if id >= 0: result.add ",\"id\":" & $id
  result.add ",\"method\":\"" & methodName & "\",\"params\":{\"textDocument\":{\"uri\":\"" &
            uriText & "\""
  if id < 0:
    result.add ",\"version\":1,\"text\":\"" & jsonEscape(text) & "\""
  result.add "}}"

proc typeInto(db: var Database; uriText: string; base: string;
              keystrokes: int): tuple[total: int64, first: int64,
                                     rest: int64] {.raises.} =
  result = (total: 0'i64, first: 0'i64, rest: 0'i64)
  ## One `didOpen` then `keystrokes` `didChange`s, timed individually so the
  ## first is reported on its own.
  discard handle(db, request("textDocument/didOpen", uriText, base))
  for k in 0 ..< keystrokes:
    let t0 = getTime()
    let body = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" &
      "{\"textDocument\":{\"uri\":\"" & uriText & "\",\"version\":" & $(k + 2) &
      "},\"contentChanges\":[{\"text\":\"" &
      jsonEscape(base & "\n# edit " & $k & "\n") & "\"}]}}"
    discard handle(db, body)
    let ms = inNanoseconds(getTime() - t0) div 1000000
    result.total += ms
    if k == 0: result.first = ms else: result.rest += ms
  if keystrokes > 1: result.rest = result.rest div (keystrokes - 1)

proc run(label: string; flag: string; keystrokes, decls: int): int64 {.raises.} =
  putEnv("NIMONY_LSP_INPROCESS", flag)
  var db = initDatabase(getCurrentDir())
  let uriText = "file://" & getCurrentDir() / "nimcache" / "lsp" / "typing.nim"
  let base = document(keystrokes, decls)
  let r = typeInto(db, uriText, base, keystrokes)
  result = r.rest
  if label.len > 0:
    stdout.writeLine label & ": total " & $r.total & "ms, first " & $r.first &
                     "ms, then " & $r.rest & "ms/keystroke"

proc main() {.raises.} =
  const keystrokes = 8
  # The first pass pays for the whole dependency closure and is reported on its
  # own. Averaging a cold start into a per-keystroke number is how that number
  # stops meaning anything -- and it is exactly the mistake the handler suite
  # makes, since it opens each document once and so is all first checks.
  # Sized to COMPLETE on a loaded machine. Three runs per size is what the noise
  # floor allowed; the first keystroke is reported separately because a cold
  # dependency closure can be an order of magnitude larger than the rest.
  # Median of N. One figure was not enough: the spread between identical runs was
  # larger than most of the effects being chased, which is how a "20% faster"
  # claim survived three commits here.
  var sub: seq[int64] = @[]
  var inp: seq[int64] = @[]
  for i in 0 .. 4:
    sub.add run("", "0", keystrokes, 60)
    inp.add run("", "1", keystrokes, 60)
  sub.sort(); inp.sort()
  let med = proc (v: seq[int64]): int64 = v[v.len div 2]
  var subTxt = ""
  for v in sub: subTxt.add $v & " "
  var inpTxt = ""
  for v in inp: inpTxt.add $v & " "
  stdout.writeLine "per-keystroke median of 5 -- subprocess " &
    $med(sub) & "ms, in-process " & $med(inp) & "ms"
  stdout.writeLine "  subprocess  " & subTxt
  stdout.writeLine "  in-process  " & inpTxt
  putEnv("NIMONY_LSP_INPROCESS", "0")

proc entry() {.raises.} =
  main()

try:
  entry()
except:
  stderr.writeLine "typing probe raised"