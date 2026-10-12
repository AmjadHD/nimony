## Hover labels must not leak Nimony's internal symbol taxonomy.
##
## The sidecar carries `NimonySym`'s tag names, which are right for codegen and
## nonsense in a popup: `glet`/`gvar` carry a SCOPE prefix, `tlet`/`tvar` a storage
## class, and `efld`/`fld`/`gfld` name an enum field, an object field and a
## constructor-guarded field. Every top-level `let` and `var` therefore used to
## hover as "``glet TopLet``" and "`gvar TopVar`", and every enum field as
## "`efld colRed`".
##
## The map lives in the LSP, not in `writeIdeQuery`: the sidecar's job is to say
## what sem knows, and how to say it to a human is this side's decision.
##
## Each assertion checks both what the label must say and what it must NOT contain,
## so a future change cannot reintroduce the tag by satisfying the first half.

import std / [assertions, os, strutils, syncio]

import ../../src/lsp/[database, handlers]

proc workDir(): string {.raises.} = "nimcache" / "lsp"

proc uriFor(rel: string): string {.raises.} = "file:///workspace/" & rel

proc lineOf(src, needle: string): int {.raises.} =
  ## The 0-based line holding the first occurrence of `needle`.
  ##
  ## DERIVED, and that is the point: a hardcoded line number is wrong the moment
  ## the fixture gains or loses a line, and a wrong line makes the query return
  ## nothing, which reads as "the kind is not rendered" rather than as a broken
  ## test. An earlier draft of this file did exactly that and failed with
  ## "TopLet: not in the fixture".
  result = -1
  let lines = src.splitLines
  for i in 0 ..< lines.len:
    if lines[i].find(needle) >= 0: return i

proc colOf(src, needle: string; line: int): int {.raises.} =
  result = -1
  let lines = src.splitLines
  if line < 0 or line >= lines.len: return
  result = lines[line].find(needle)

type Checker = object
  db: Database
  uri: string

proc openChecked(text, rel: string): Checker {.raises.} =
  result = Checker(uri: uriFor(rel))
  # initDatabase first: it is the proc that creates `nimcache/lsp`.
  result.db = initDatabase(getCurrentDir())
  writeFile(workDir() / rel, text)
  var d = result.db.updateDocument(result.uri, workDir() / rel, 1, text)
  result.db.runDiagnostics(d)

proc params(uri: string; line, character: int): string {.raises.} =
  result = "{\"textDocument\":{\"uri\":\"" & uri &
    "\"},\"position\":{\"line\":" & $line & ",\"character\":" & $character & "}}"

proc hoverAt(c: var Checker; line, character: int): string {.raises.} =
  let res = handle(c.db, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\"," &
    "\"params\":" & params(c.uri, line, character) & "}")
  if res.response.len == 0: return "<no response>"
  let cut = res.response.find("\"value\":")
  if cut < 0: return res.response
  # `cut + 8` is the value's OPENING quote, so searching for a quote from there
  # finds that one and yields an empty label. The label starts one past it.
  let first = cut + 9
  let stop = res.response.find("\"", first)
  if stop < 0: return res.response
  result = res.response[first ..< stop]

proc check(src, rel, needle: string; mustContain, mustNotContain: string) {.raises.} =
  var c = openChecked(src, rel)
  let line = lineOf(src, needle)
  assert line >= 0, needle & ": not in the fixture"
  let col = colOf(src, needle, line)
  assert col >= 0, needle & ": found on its line but not in it"
  let label = hoverAt(c, line, col)
  assert label.contains(mustContain),
         needle & ": expected to contain \"" & mustContain & "\", got " & label
  assert not label.contains(mustNotContain),
         needle & ": leaked the internal tag \"" & mustNotContain &
         "\" into the label: " & label

const Fixture = """
type Col* = enum
  colRed
type Cfg = object
  name*: string
const TopConst = 1
let TopLet = 2
var TopVar = 3
proc zzP(a: int): int =
  let innerLet = a
  var innerVar = a
  result = innerLet + innerVar + a
discard TopConst
discard TopLet
discard TopVar
discard zzP(1)
"""

proc checkKinds() {.raises.} =
  # `glet`/`gvar`: the module-scope prefix is the compiler's, not the reader's.
  check(Fixture, "kinds.nim", "TopLet",
        mustContain = "`let TopLet`", mustNotContain = "glet")
  check(Fixture, "kinds.nim", "TopVar",
        mustContain = "`var TopVar`", mustNotContain = "gvar")
  # `efld`: an enum field is a field.
  check(Fixture, "kinds.nim", "colRed",
        mustContain = "colRed", mustNotContain = "efld")
  # Kinds that were already right must STAY right -- the map is a rename table,
  # not a replacement, and a blanket rewrite would break these.
  check(Fixture, "kinds.nim", "TopConst",
        mustContain = "`const TopConst`", mustNotContain = "gconst")
  check(Fixture, "kinds.nim", "innerVar",
        mustContain = "`var innerVar`", mustNotContain = "gvar")
  check(Fixture, "kinds.nim", "Col",
        mustContain = "`type Col`", mustNotContain = "gtype")

proc checkUnknownKindOmitsIt() {.raises.} =
  ## `NoSym` means the kind was not resolved. Printing the enum's own name for it
  ## is strictly worse than printing nothing, so the kind is left out -- which is
  ## what the lexical path has always done with an empty `declarationKind`.
  var c = openChecked(Fixture, "kinds_unknown.nim")
  let line = lineOf(Fixture, "name*: string")
  assert line >= 0
  let col = colOf(Fixture, "name*: string", line)
  assert col >= 0
  let label = hoverAt(c, line, col)
  assert not label.contains("NoSym"),
         "an unresolved kind printed the enum's own name: " & label
  assert label.contains("name"),
         "a record field's hover lost the name entirely: " & label

try:
  checkKinds()
  checkUnknownKindOmitsIt()
except:
  assert false, "symbol-kind display test failed"