## Hover and go-to-definition on a module NAME in an import list.
##
## This used to answer nothing at all -- hover `null`, definition `[]` -- while
## every other identifier in the same file answered perfectly. The reason was not
## that modules are hard to resolve: `doImports` replaces the name with
## `(kv <suffix> "<file>")`, so by the time `walkIdePositions` reads the finished
## phase-3 tree the identifier is gone along with its line info. Every other
## occurrence in the file is found by that walker; this one was not in the tree to
## be found.
##
## Each case below is a different branch of `filenameVal`, because they reach the
## recorder by different routes: a bare name, a slash path, an alias, and a
## from-import.
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

proc params(uri: string; line, character: int): string {.raises.} =
  result = "{\"textDocument\":{\"uri\":\"" & uri &
    "\"},\"position\":{\"line\":" & $line & ",\"character\":" & $character & "}}"

type Checker = object
  ## One document, registered and CHECKED once -- registering is not checking, so a
  ## document registered any other way answers every query with nothing.
  db: Database
  uri: string
  diagnostics: int

proc openChecked(text, rel: string): Checker {.raises.} =
  result = Checker(uri: uriFor(rel), diagnostics: 0)
  # initDatabase first: it is the proc that creates `nimcache/lsp`.
  result.db = initDatabase(getCurrentDir())
  writeFile(workDir() / rel, text)
  var d = result.db.updateDocument(result.uri, workDir() / rel, 1, text)
  result.db.runDiagnostics(d)
  result.diagnostics = d.diagnostics.len + d.semanticDiagnostics.len

proc ask(c: var Checker; verb: string; line, character: int): string {.raises.} =
  let res = handle(c.db, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"" & verb &
    "\",\"params\":" & params(c.uri, line, character) & "}")
  if res.response.len == 0: return "<no response>"
  let cut = res.response.find("\"result\":")
  if cut < 0: return res.response
  result = res.response[cut .. ^1]

const
  ## `ask` hands back the response from `"result":` onward, so these are the two
  ## shapes of "nothing to say" -- each named rather than spelled at the call
  ## site, where a typo would read as a check that can never fail.
  NullAnswer = "\"result\":null}"
  EmptyArray = "\"result\":[]}"

proc checkBoth(c: var Checker; src, needle: string; line, occurrence = 1;
               what, mustContain: string) {.raises.} =
  ## Both answers are required. Asserting only that they are non-empty would let a
  ## broken-file answer that merely echoes a well-formed empty result pass.
  let col = colOf(src, needle, line, occurrence)
  assert col >= 0, what & ": the needle is not in the fixture at all"
  let hover = c.ask("textDocument/hover", line, col)
  let definition = c.ask("textDocument/definition", line, col)
  assert hover.contains("module") and hover.contains(needle),
         what & ": hover did not name the module\n  " & hover
  assert definition.contains(mustContain),
         what & ": definition did not resolve\n  " & definition

proc checkBareName() {.raises.} =
  ## `of Ident` in `filenameVal`: a module with no slash at all.
  let src = "import std/strutils\n"
  var c = openChecked(src, "imp_bare.nim")
  checkBoth(c, src, "strutils", 0, what = "a slash-separated module",
            mustContain = "strutils.nim")

proc checkFromImport() {.raises.} =
  ## `semFromImport` reaches the same `doImports`.
  let src = "from std/os import getAppFilename\n"
  var c = openChecked(src, "imp_from.nim")
  checkBoth(c, src, "os", 0, what = "a module in a from-import",
            mustContain = "os.nim")

proc checkAlias() {.raises.} =
  ## `import a/b as c`: the bound name is `c`, and that is what is recorded. The
  ## path's own component deliberately is not -- `b` is not a name this module
  ## binds, so answering it would name a symbol nothing refers to.
  let src = "import std/os as zzmod\n"
  var c = openChecked(src, "imp_alias.nim")
  checkBoth(c, src, "zzmod", 0, what = "an aliased module",
            mustContain = "os.nim")
  let onPath = colOf(src, "os", 0)
  let hover = c.ask("textDocument/hover", 0, onPath)
  assert hover.contains(NullAnswer),
         "the aliased path component unexpectedly answers; if that is intended " &
         "now, update this assertion and the comment on `filenameVal`: " & hover

proc checkTwoOnOneLine() {.raises.} =
  ## Two modules in one statement: the later one must not shadow the earlier.
  let src = "import std/os, std/strutils\n"
  var c = openChecked(src, "imp_two.nim")
  checkBoth(c, src, "os", 0, what = "the first of two imports",
            mustContain = "os.nim")
  checkBoth(c, src, "strutils", 0, what = "the second of two imports",
            mustContain = "strutils.nim")

proc checkMissingModuleIsQuiet() {.raises.} =
  ## An unresolvable module must stay an ordinary diagnostic, not a crash and not
  ## a recorded occurrence pointing at nothing.
  let src = "import zzzNoSuchModuleAnywhere\n"
  var c = openChecked(src, "imp_missing.nim")
  assert c.diagnostics > 0, "a missing module produced no diagnostic at all"
  let col = colOf(src, "zzzNoSuchModuleAnywhere", 0)
  assert c.ask("textDocument/hover", 0, col).contains(NullAnswer),
         "an unresolved module name answered a hover instead of nothing"
  assert c.ask("textDocument/definition", 0, col).contains(EmptyArray),
         "an unresolved module name answered a definition instead of nothing"

proc checkOtherIdentifiersStillWork() {.raises.} =
  ## The fix adds a record; it must not displace the ones the walker already made.
  let src = "import std/os\n\nproc zzProbe(): string =\n  getAppFilename()\n"
  var c = openChecked(src, "imp_mixed.nim")
  let col = colOf(src, "getAppFilename", 3)
  let hover = c.ask("textDocument/hover", 3, col)
  assert hover.contains("getAppFilename"),
         "an imported symbol stopped answering while the module name started: " & hover
  assert c.ask("textDocument/definition", 3, col).contains("os.nim"),
         "go-to-definition on an imported symbol regressed"

proc checkSymbolIsQualified() {.raises.} =
  ## `getAppFilename` must read as `os.getAppFilename`. Without the module, a bare
  ## name cannot tell two same-named symbols from different modules apart, which is
  ## the one thing a hover exists to settle. nimsuggest's `qualifiedPath` does the
  ## same, and names the DEFINING module: after `import std/os as zzmod` it is
  ## still `os.foo`, which is why the qualifier is derived from the declaring file
  ## rather than from what this file happened to alias it to.
  let src = "import std/os\n\nproc zzProbe(): string =\n  getAppFilename()\n"
  var c = openChecked(src, "imp_qualified.nim")
  let hover = c.ask("textDocument/hover", 3, colOf(src, "getAppFilename", 3))
  assert hover.contains("os.getAppFilename"),
         "an imported symbol is not qualified by its module: " & hover
  # A symbol in THIS document needs none, and giving it one would be as wrong as
  # omitting one from a stdlib symbol.
  let local = c.ask("textDocument/hover", 2, colOf(src, "zzProbe", 2))
  assert not local.contains(".zzProbe"),
         "a symbol in this document was given a module qualifier: " & local

proc checkModuleDocIsTheModulesOwn() {.raises.} =
  ## `strutils.nim` opens with a doc block, so hovering the module must show THAT.
  ## It showed `fileExists`'s doc for `std/os` until this: `docCommentAt` scans
  ## DOWN from the declaration's line, and a module's candidate points at line 0,
  ## so the block it found was the one under it -- the first declaration's.
  let src = "import std/strutils\n"
  var c = openChecked(src, "imp_moddoc.nim")
  let hover = c.ask("textDocument/hover", 0, colOf(src, "strutils", 0))
  assert hover.contains("ASCII-focused"),
         "a module's hover did not carry the module's own doc: " & hover

proc checkModuleWithoutDocShowsNone() {.raises.} =
  ## `os.nim` opens with `import`, so it has no module doc of its own. Showing the
  ## first declaration's instead is worse than showing nothing, so the label must
  ## come back with no doc section at all -- a doc always adds a blank line.
  let src = "import std/os\n"
  var c = openChecked(src, "imp_nomoddoc.nim")
  let hover = c.ask("textDocument/hover", 0, colOf(src, "os", 0))
  assert hover.contains("`module os`"),
         "a module without a doc lost its label: " & hover
  assert not hover.contains("\\n\\n"),
         "a module with no doc comment showed a doc anyway: " & hover

try:
  checkBareName()
  checkFromImport()
  checkAlias()
  checkTwoOnOneLine()
  checkMissingModuleIsQuiet()
  checkOtherIdentifiersStillWork()
  checkSymbolIsQualified()
  checkModuleDocIsTheModulesOwn()
  checkModuleWithoutDocShowsNone()
except:
  assert false, "module-name-in-import query test failed"