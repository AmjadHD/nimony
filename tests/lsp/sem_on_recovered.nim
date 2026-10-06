## Does sem survive the trees the recovering parser produces?
##
## The recovery corpus stops at the parser: it asserts that a recovered tree is
## balanced, keeps its bytes, and consumed its input. Nothing ever fed one to sem.
##
## That is the wrong place to stop, because a recovered tree is not an edge case
## in this editor -- `recovering = true` is how every document is parsed for a
## query, so sem runs on recovered trees constantly and untested. A parser that
## repairs its output and a sem phase that can assume well-formedness are different
## properties, and only the first has been established.
##
## This asks the second one, through the path that actually runs: open a
## malformed document, let the database parse it with recovery, hand the result to
## sem as a pre-parsed `.nif`, and require that sem *finishes*. A crash inside the
## compiler surfaces as `semantic analysis failed` in the diagnostics, which is what
## the first assertion rules out. A repaired tree that sem then cannot make sense
## of shows up as a flood instead, which is what the second rules out.
##
## `.nojoin`: it shells out to the compiler per case.

import std / [assertions, os, osproc, strutils, syncio]
import ../../src/lsp/[database, handlers]

const fixtureDir = "tests" / "lsp" / "fixtures" / ".." / "parser_recovery"

proc checkRecovered(label, text: string) {.raises.} =
  let uri = "file:///workspace/recovered-" & label & ".nim"
  var db = initDatabase(getCurrentDir())
  let opened = handle(db, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{" &
    "\"textDocument\":{\"uri\":\"" & uri & "\",\"languageId\":\"nim\",\"version\":1,\"text\":\"" &
    text.replace("\n", "\\n") & "\"}}}")
  # The compiler is a subprocess, so a crash is reported rather than raised. This is
  # the whole assertion: sem finished on a tree the parser had to repair.
  assert not opened.notification.contains("semantic analysis failed"),
         label & ": sem did not survive the recovered tree: " & opened.notification
  # A repaired tree sem cannot make sense of produces a diagnostic per token rather
  # than a handful. Any bound catches that; the number is deliberately loose.
  var count = 0
  var rest = opened.notification
  while rest.find("\"message\":") >= 0:
    inc count
    rest = rest[rest.find("\"message\":") + 9 .. ^1]
  assert count > 0,
         label & ": nothing was diagnosed, so nothing was recovered either"
  stdout.writeLine label & ": " & $count & " diagnostics, sem finished"
  assert count < 60,
         label & ": " & $count & " diagnostics from a few lines is a flood, not a parse"

proc runTests() {.raises.} =
  # Each fixture alone, which is what the corpus covers, and then all of them
  # concatenated -- several unrelated injuries in one file is a shape no single
  # fixture produces and is closer to what a real mid-edit buffer looks like.
  # This stdlib has no directory walk at all, so the listing is done with `ls`.
  var names: seq[string] = @[]
  let (listing, _) = execCmdEx("ls " & fixtureDir)
  for entry in listing.splitLines:
    if entry.endsWith(".nim.txt"): names.add fixtureDir / entry

  for path in names:
    checkRecovered(splitFile(path).name, readFile(path))

  var joined = ""
  for path in names:
    joined.add readFile(path)
    joined.add "\n"
  checkRecovered("joined", joined)

  # A declaration cut in half, which is the shape an editor is in between two
  # keystrokes and the one the recovery work was written for.
  checkRecovered("truncated-proc",
                "type Color = enum\n  colRed, colGreen\n\nproc partial(k: Color) =\n  k.\n")

try:
  runTests()
except:
  assert false, "sem-on-recovered-tree test raised"