## Hover documentation for everything that is not a proc or a module.
##
## A hover on a proc or a module already carried its `##` block; types, vars,
## lets, consts and inline docs worked too. Two things did not, and both were
## asked as one question ("what about fields, and what about the docs that are
## written inline?"):
##
##   - A FIELD could not be placed at all. Its symbol is local (`x.0`, no module
##     suffix), so the module index has no row for it, and the field lives in its
##     object type's scope, which no walk of the finished module reaches. Sem
##     resolves a field access through the owner type and is the only side that
##     ever holds both the access and the declaration; `IdeQuery.fieldDefs` is
##     where it leaves that answer, keyed by the access's own position.
##
##   - An INLINE `##`, at the end of a declaration's own line, was only found for
##     the open document, and only through a parser-recorded table. Another file
##     was scanned for a block starting on the line BELOW the declaration, so a
##     field with `## doc` on its line answered with the NEXT field's doc -- the
##     worst possible answer, because it looks like a real one. The lookup now
##     checks the declaration's own last line first (a wrapped signature is
##     skipped by bracket depth), then a block that starts its own line below.
##     A `##` trailing the next declaration's line belongs to that declaration,
##     and a negative case here pins that it stays out of the previous one's.
##
## Positions are DERIVED from the text, never hand-counted: an off-by-one column
## makes the query return empty and the response well-formed, which is
## indistinguishable from the very bug this test is about.

import std / [assertions, os, strutils, syncio]

import ../../src/lsp/[database, handlers]

proc workDir(): string {.raises.} = "nimcache" / "lsp"

proc uriFor(rel: string): string {.raises.} = "file:///workspace/" & rel

proc colOf(src, needle: string; line, occurrence = 1): int {.raises.} =
  ## The column the `occurrence`-th `needle` starts at on 0-based `line`.
  result = -1
  let lines = src.splitLines
  if line < 0 or line >= lines.len: return
  for _ in 1 .. occurrence:
    result = lines[line].find(needle, result + 1)

proc lineOf(src, needle: string): int {.raises.} =
  ## The 0-based line holding the first `needle`, so a position is taken from
  ## the fixture instead of from a comment that can drift.
  result = -1
  let lines = src.splitLines
  for i in 0 ..< lines.len:
    if lines[i].find(needle) >= 0: return i

proc params(uri: string; line, character: int): string {.raises.} =
  result = "{\"textDocument\":{\"uri\":\"" & uri &
    "\"},\"position\":{\"line\":" & $line & ",\"character\":" & $character & "}}"

type Checker = object
  db: Database
  uri: string
  firstDiagnostic: string

proc openChecked(text, rel: string): Checker {.raises.} =
  result = Checker(uri: uriFor(rel), firstDiagnostic: "")
  # initDatabase first: it is the proc that creates `nimcache/lsp`.
  result.db = initDatabase(getCurrentDir())
  writeFile(workDir() / rel, text)
  var d = result.db.updateDocument(result.uri, workDir() / rel, 1, text)
  result.db.runDiagnostics(d)
  if d.diagnostics.len > 0: result.firstDiagnostic = d.diagnostics[0].message
  elif d.semanticDiagnostics.len > 0:
    result.firstDiagnostic = d.semanticDiagnostics[0].message

proc ask(c: var Checker; verb: string; line, character: int): string {.raises.} =
  let res = handle(c.db, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"" & verb &
    "\",\"params\":" & params(c.uri, line, character) & "}")
  if res.response.len == 0: return "<no response>"
  let cut = res.response.find("\"result\":")
  if cut < 0: return res.response
  result = res.response[cut .. ^1]

const Helper = """type
  ZzHelper* = object
    hField*: int
      ## Doc for hField.
    hInline*: string ## Doc for hInline.
    hNodoc*: int
    hNext*: int ## Doc for hNext.

  ZzEnum* = enum
    zzOne, ## Doc for zzOne.
    zzTwo  ## Doc for zzTwo.

const zzHelperConst* = 7 ## Doc for zzHelperConst.
"""

const Main = """import hoverdocs_helper

type
  ZzType* = object
    ## Doc for ZzType.
    zzField*: int
      ## Doc for zzField.
    zzPlain*: string ## Doc for zzPlain.
    zzNodoc*: int
    zzNext*: int ## Doc for zzNext.

proc zzProc*() =
  ## Doc for zzProc.
  discard

var zzVar*: int
  ## Doc for zzVar.

let zzLet* = 5
  ## Doc for zzLet.

const zzConst* = 6 ## Doc for zzConst.

let zzUseT = ZzType(zzField: 1, zzPlain: "x", zzNodoc: 2, zzNext: 3)
let zzUseF = zzUseT.zzField
let zzUseP = zzUseT.zzPlain
let zzUseN = zzUseT.zzNodoc
let zzUseX = zzUseT.zzNext
let zzHUse = ZzHelper(hField: 1, hInline: "x")
let zzHGet = zzHUse.hField
let zzHGet2 = zzHUse.hInline
let zzHNodoc = zzHUse.hNodoc
let zzENUse = zzOne
let zzENUse2 = zzTwo
let zzCUse = zzHelperConst
let zzPUse = zzProc
let useVar = zzVar
let useLet = zzLet
let useConst = zzConst
"""

proc hoverAt(c: var Checker; src, needle: string; line, occurrence = 1): string {.raises.} =
  let col = colOf(src, needle, line, occurrence)
  assert col >= 0, "needle '" & needle & "' is not on fixture line " & $line
  result = c.ask("textDocument/hover", line, col)

proc checkMain() {.raises.} =
  # The helper has to be on disk before the importer is checked; registering it
  # as an open document is not needed, only its text.
  discard initDatabase(getCurrentDir())
  writeFile(workDir() / "hoverdocs_helper.nim", Helper)
  var c = openChecked(Main, "hoverdocs_main.nim")
  assert c.firstDiagnostic.len == 0,
         "the fixture failed to check: " & c.firstDiagnostic

  let declLine = lineOf(Main, "zzField*: int")
  assert declLine >= 0
  let declCol = colOf(Main, "zzField", declLine)

  # A field reached through a dot: the answer must name the declaration, carry
  # its doc, and be labeled as a field rather than left kindless.
  let dot = c.hoverAt(Main, "zzField", lineOf(Main, "zzUseF"))
  assert dot.contains("`field zzField`"),
         "a field use is not labeled as a field: " & dot
  assert dot.contains("Doc for zzField."),
         "a field's own doc is missing: " & dot
  assert dot.contains("\"line\":" & $declLine & ",\"character\":" & $declCol),
         "a field hover does not point at its declaration: " & dot

  # The same field reached through an object constructor reaches the resolver by
  # the other call path, and must land in the same place.
  let ctor = c.hoverAt(Main, "zzPlain", lineOf(Main, "zzUseT"))
  assert ctor.contains("`field zzPlain`") and ctor.contains("Doc for zzPlain."),
         "an inline-documented field in a constructor lost its doc: " & ctor

  # A field with no doc of its own must stay WITHOUT one. The line below it is
  # another field whose inline `##` documents that field; reading it as this
  # one's is the wrong-doc failure this lookup exists to prevent.
  let nodoc = c.hoverAt(Main, "zzNodoc", lineOf(Main, "zzUseN"))
  assert nodoc.contains("`field zzNodoc`"),
         "a field without a doc is not even labeled: " & nodoc
  assert not nodoc.contains("Doc for zzNext."),
         "a field answered with the NEXT field's doc: " & nodoc

  # ...while the next field's own doc is found for the next field.
  let next = c.hoverAt(Main, "zzNext", lineOf(Main, "zzUseX"))
  assert next.contains("Doc for zzNext."),
         "the doc of the field after an undocumented one is missing: " & next

  # On the field's declaration itself. The node is a `SymbolDef` whose symbol
  # resolves nowhere, so sem records the declaration under its own position too.
  let decl = c.hoverAt(Main, "zzField", declLine)
  assert decl.contains("Doc for zzField."),
         "a field is undocumented at its own declaration: " & decl

  # Imported: the declaration is in another file, so the doc is read from that
  # file -- the inline/below decision has to be made there as well.
  let fieldLine = lineOf(Main, "zzHGet =")
  let helperFieldLine = lineOf(Helper, "hField*: int")
  let imported = c.hoverAt(Main, "hField", fieldLine)
  assert imported.contains("`field hoverdocs_helper.hField`"),
         "an imported field is not labeled or qualified: " & imported
  assert imported.contains("Doc for hField."),
         "an imported field's doc is missing: " & imported
  # Hover carries no URI, so the file a field is declared in shows up as the
  # range: the one place an editor underlines is the declaration, wherever it is.
  assert imported.contains("\"line\":" & $helperFieldLine),
         "an imported field's range is not its declaration's: " & imported
  let definition = c.ask("textDocument/definition", fieldLine,
                         colOf(Main, "hField", fieldLine))
  assert definition.contains("hoverdocs_helper.nim") and
         definition.contains("\"line\":" & $helperFieldLine),
         "go-to-definition on an imported field did not reach the declaration: " &
         definition

  let inlineField = c.hoverAt(Main, "hInline", lineOf(Main, "zzHGet2"))
  assert inlineField.contains("Doc for hInline."),
         "an imported INLINE field doc was not found: " & inlineField

  let importedNodoc = c.hoverAt(Main, "hNodoc", lineOf(Main, "zzHNodoc"))
  assert importedNodoc.contains("`field hoverdocs_helper.hNodoc`"),
         "an imported field without a doc is not even labeled: " & importedNodoc
  assert not importedNodoc.contains("Doc for hNext."),
         "an imported field answered with the NEXT field's doc: " & importedNodoc

  # Enum fields are a different symbol kind, and their docs are written inline
  # at the end of the member's own line. Reading the line below is how `zzOne`
  # came to answer with `zzTwo`'s doc.
  let one = c.hoverAt(Main, "zzOne", lineOf(Main, "zzENUse"))
  assert one.contains("Doc for zzOne."),
         "an enum field's inline doc was not found: " & one
  assert not one.contains("Doc for zzTwo."),
         "an enum field answered with its neighbour's doc: " & one
  let two = c.hoverAt(Main, "zzTwo", lineOf(Main, "zzENUse2"))
  assert two.contains("Doc for zzTwo."),
         "the second enum member's inline doc was not found: " & two

  let constUse = c.hoverAt(Main, "zzHelperConst", lineOf(Main, "zzCUse"))
  assert constUse.contains("Doc for zzHelperConst."),
         "an imported const's inline doc was not found: " & constUse

  # And the kinds that already worked must keep working; a lookup that starts
  # answering from the wrong side would break one of these first.
  let symType = c.hoverAt(Main, "ZzType", lineOf(Main, "zzUseT"))
  assert symType.contains("Doc for ZzType."),
         "an object type lost its doc: " & symType
  let procUse = c.hoverAt(Main, "zzProc", lineOf(Main, "zzPUse"))
  assert procUse.contains("Doc for zzProc."),
         "a proc lost its doc: " & procUse
  let varUse = c.hoverAt(Main, "zzVar", lineOf(Main, "useVar"))
  assert varUse.contains("Doc for zzVar."),
         "a var lost its doc: " & varUse
  let letUse = c.hoverAt(Main, "zzLet", lineOf(Main, "useLet"))
  assert letUse.contains("Doc for zzLet."),
         "a let lost its doc: " & letUse
  let constUse2 = c.hoverAt(Main, "zzConst", lineOf(Main, "useConst"))
  assert constUse2.contains("Doc for zzConst."),
         "a const lost its doc: " & constUse2

try:
  checkMain()
except:
  assert false, "hover documentation test failed"
