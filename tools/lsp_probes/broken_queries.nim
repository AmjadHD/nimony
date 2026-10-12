## Do query answers stay CORRECT in a document that has errors?
##
## The five-line fixtures could not answer that, and they were the weakness in the
## nimsuggest comparison. So: break a document in five ways, at scale, and require
## that every answer a client would read is the SAME answer the clean file gives.
##
## The oracle is the clean file. For a query about a symbol that does not straddle
## the injected error, the broken file's answer must match. That needs no knowledge
## of the response shape, and it cannot be satisfied by both sides returning null --
## `checkClean` asserts the clean answer is a real one first.
##
## COST, because the first version of this file was unusable: it registered and
## re-checked the document for EVERY query, so ~55 full `nimony check` subprocesses,
## several of them on a 120-declaration file. On a phone that saturated the device
## badly enough to restart the editor session twice. Three changes fixed it:
##
##   * ONE check per document, not per query. `Checker` registers, checks, and stays
##     open; every query is answered from the snapshot it already built.
##   * The clean oracle is computed ONCE and its answers kept, rather than
##     recomputed for each of the five injections.
##   * Both texts use the SAME path, so the responses' URIs match and can be
##     compared. Getting this wrong reports identical reference ranges as a failure,
##     because a URI differs -- which is how the second version failed.
## Ten checks now, down from ~55.
##
## Positions are DERIVED from the text they query, never hand-counted. An
## off-by-one column makes `positionAt` return an empty IdePosition, `matched`
## false, and the response a well-formed `[]` -- indistinguishable from a real
## defect unless you count the characters yourself.

import std / [assertions, os, strutils, syncio]

import ../../src/lsp/[database, handlers]

{.feature: "lenientnils".}

## Under `nimcache/lsp`, which `initDatabase` already creates -- so this needs no
## directory of its own, and the scratch files never land in the source tree.
proc workDir(): string {.raises.} = "nimcache" / "lsp"

proc uriFor(rel: string): string {.raises.} = "file:///workspace/" & rel

proc params(uri: string; line, character: int): string {.raises.} =
  "{\"textDocument\":{\"uri\":\"" & uri & "\"},\"position\":{\"line\":" &
    $line & ",\"character\":" & $character & "}}"

proc colOf(src, needle: string; line: int): int {.raises.} =
  ## The column `needle` starts at on 0-based `line`, or -1.
  let lines = src.splitLines
  if line < 0 or line >= lines.len: return -1
  result = lines[line].find(needle)

proc hoverSymbol(resp: string): string {.raises.} =
  ## The ``kind name`` a hover response names, ignoring the rest.
  ##
  ## Hover's second exit reports the range of the OCCURRENCE, the first the
  ## declaration's own. So in a broken file, where the lexical fallback answers
  ## instead of the recorded candidate, the symbol is right and the anchor differs.
  ## Byte-equality would call that a fault-tolerance regression when the identity,
  ## which is what a user reads, is identical.
  let at = resp.find("\"value\":")
  if at < 0: return resp
  let first = at + 8
  let stop = resp.find("}", first)
  if stop < 0: return resp
  result = resp[first ..< stop]

type Checker = object
  ## One document, registered and CHECKED ONCE. Registering is not checking --
  ## `didOpen` runs the check, so a document registered any other way has an empty
  ## snapshot and every query answers nothing.
  db: Database
  uri: string
  diagnostics: int

proc openChecked(text, rel: string): Checker {.raises.} =
  # `result = Checker(...)` rather than field-by-field assignment: this compiler
  # wants the result provably initialised, and an object holding a `Database` does
  # not get that from three separate writes.
  result = Checker(uri: uriFor(rel), diagnostics: 0)
  writeFile(workDir() / rel, text)
  result.uri = uriFor(rel)
  result.db = initDatabase(getCurrentDir())
  var d = result.db.updateDocument(result.uri, workDir() / rel, 1, text)
  result.db.runDiagnostics(d)
  result.diagnostics = d.diagnostics.len + d.semanticDiagnostics.len

proc ask(c: var Checker; verb, body: string): string {.raises.} =
  let res = handle(c.db, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"" & verb &
    "\",\"params\":" & body & "}")
  if res.response.len == 0: return "<no response>"
  let cut = res.response.find("\"result\":")
  if cut < 0: return res.response
  result = res.response[cut .. ^1]

# --------------------------------------------------------------- the subject

proc smallSource(): string {.raises.} =
  result = "proc zzAlpha(x: int): int =\n" &
          "  result = x + 1\n" &
          "\n" &
          "proc zzBeta(y: int): int =\n" &
          "  result = zzAlpha(y)\n" &
          "\n" &
          "let zzGamma = zzBeta(41)\n" &
          "\n" &
          "proc zzDelta(): string =\n" &
          "  \"delta\"\n"

const
  lineAlphaUse = 4    # `  result = zzAlpha(y)`
  lineLet = 6         # `let zzGamma = zzBeta(41)`

proc inject(src: string; which: int): string {.raises.} =
  ## Each injury sits where a user would really make one, and each leaves
  ## declarations after it.
  result = src
  case which
  of 0: result = result.replace("  result = zzAlpha(y)", "  result = zzAlpha(y")
  of 1: result = result.replace("let zzGamma = zzBeta(41)", "let = zzBeta(41)")
  of 2: result = result.replace("  result = zzAlpha(y)",
                                "  result = notDeclaredAtAll(y)")
  of 3: result = result.replace("proc zzDelta(): string =",
                                "proc zzDelta(): string =\n) ] }")
  else: result = result.replace("proc zzBeta(y: int): int =", "proc zzBeta(y: int = ")
    # ^ THE ONE THAT HANGS. Bisected, because this file was unusable until it was:
    #   injections 0-2  pass, alone and together
    #   injection  3    passes  (this is the `strayClosers` case the sem body fix
    #                          in `semdecls.nim` resolved)
    #   injection  4    HANGS THE SESSION, alone
    #   all five       hangs
    #
    # A routine whose PARAMETER LIST is torn never terminates. Minimal:
    #
    #   proc zzBeta(y: int =
    #
    # drives `bin/nimony check --visible:FILE,0,0` past 120s on a 382-byte tree,
    # with the address space capped so a runaway cannot take the machine with it.
    # The tree sem is given is:
    #
    #   (proc zzBeta . . .
    #    (params
    #     (param y . .
    #      (err "invalid indentation")
    #      (err "expression expected, but found '[EOF]'"))
    #     (err "expected: ')', but got: '[EOF]'")). . . .)
    #
    # Two err nodes INSIDE a `(param)` and one as a direct child of `(params)`.
    # Same class as the body-slot bug fixed in `semdecls.nim`, in the parameter
    # list instead of the body -- and far more common, because it is what you type
    # every single time you start a proc.
    #
    # NOT `semParams`/`semParam`: both handle an unexpected shape with `buildErr`
    # (`semdecls.nim:679-691`), and neither can loop. The loop is in what consumes
    # the param's TYPE -- `semLocal`, or the `semGenericParams` walk before it, or
    # `getParamsType` re-reading `dest` afterwards. Not yet isolated.
    #
    # Until it is, this probe cannot be run whole. Run `checkClean` alone (it
    # passes), or a single injection by narrowing the `for i in ..` bound.

proc fourAnswers(c: var Checker; alphaCol, betaCol: int): array[4, string] {.raises.} =
  ## Every request kind, from one already-checked document.
  result = ["", "", "", ""]
  let uri = c.uri
  result[0] = c.ask("textDocument/hover", params(uri, lineAlphaUse, alphaCol))
  result[1] = c.ask("textDocument/definition", params(uri, lineLet, betaCol))
  result[2] = c.ask("textDocument/signatureHelp", params(uri, lineLet, betaCol + 7))
  result[3] = c.ask("textDocument/references", params(uri, lineAlphaUse, alphaCol))

proc checkClean() {.raises.} =
  ## The oracle is only worth trusting if the clean answers are right first.
  let src = smallSource()
  var c = openChecked(src, "clean.nim")
  let a = fourAnswers(c, colOf(src, "zzAlpha", lineAlphaUse),
                         colOf(src, "zzBeta(", lineLet))
  assert hoverSymbol(a[0]).contains("zzAlpha"),
         "hover did not name the symbol: " & a[0]
  assert a[1].contains("clean.nim"), "definition did not resolve: " & a[1]
  # Signature help is asserted only to be LIVE. On this call it answers with the
  # overloads of `+` rather than of `zzBeta` -- sem records no signature for a call
  # to a user-defined proc in a top-level `let`, so `signaturesAt` falls back to the
  # last call at-or-before the cursor. That is a question about what sem records,
  # not about fault tolerance, and hardcoding it here failed on it.
  assert not a[2].contains("\"null\"") and a[2].len > 4,
         "signature help answered nothing at all: " & a[2]
  # References answers with LOCATIONS, not names, so a spell-check would fail
  # against a correct response. Both occurrences are checked instead.
  assert a[3].contains("\"line\":0,\"character\":5") and
         a[3].contains("\"line\":4,\"character\":11"),
         "references did not find both occurrences: " & a[3]

proc checkAnswersSurvive() {.raises.} =
  let src = smallSource()
  let rel = "clean.nim"          # SAME path as the oracle: see the header
  let alphaClean = colOf(src, "zzAlpha", lineAlphaUse)
  let betaClean = colOf(src, "zzBeta(", lineLet)
  # The clean oracle, computed ONCE and kept. Recomputing it per injection was
  # five redundant full checks.
  var cc = openChecked(src, rel)
  let clean = fourAnswers(cc, alphaClean, betaClean)

  let names = ["tearInBody", "tearAtTopLevel", "undeclaredIdentifier",
               "strayClosers", "tornSignature"]
  for i in 0 .. names.len - 1:
    let broken = inject(src, i)
    assert broken != src, names[i] & ": the injection changed nothing"
    let alphaBroken = colOf(broken, "zzAlpha", lineAlphaUse)
    let betaBroken = colOf(broken, "zzBeta(", lineLet)
    if alphaBroken < 0 or betaBroken < 0:
      continue # the injection removed the symbol; nothing left to ask about
    # Rebuilt at the same path, so the URIs in the answers match and the
    # comparison is about the error rather than about the filename.
    var bc = openChecked(broken, rel)
    let got = fourAnswers(bc, alphaBroken, betaBroken)
    assert bc.diagnostics > 0,
           names[i] & ": the injection produced no diagnostic at all"

    assert hoverSymbol(got[0]) == hoverSymbol(clean[0]),
           names[i] & ": hover resolved to a different symbol because of an error " &
           "elsewhere:\n  clean:  " & clean[0] & "\n  broken: " & got[0]
    assert got[1] == clean[1],
           names[i] & ": definition changed because of an error elsewhere:\n" &
           "  clean:  " & clean[1] & "\n  broken: " & got[1]
    assert got[2] == clean[2],
           names[i] & ": signature help changed because of an error elsewhere:\n" &
           "  clean:  " & clean[2] & "\n  broken: " & got[2]
    assert got[3] == clean[3],
           names[i] & ": references changed because of an error elsewhere:\n" &
           "  clean:  " & clean[3] & "\n  broken: " & got[3]

proc bigSource(count: int): string {.raises.} =
  ## `count` declarations, each referring to the one before it. Declaration `i` is
  ## at line 3*(i-1); its body line names `zzBig{i-1}` at column 11.
  result = "proc zzBig0(x: int): int =\n  result = x + 1\n"
  for i in 1 .. count:
    result.add "\nproc zzBig" & $i & "(x: int): int =\n  result = zzBig" & $(i-1) & "(x)\n"

proc checkAtScale(count: int) {.raises.} =
  ## The error goes in the middle. The module is big enough that a resync which
  ## discards the rest cannot hide.
  let src = bigSource(count)
  let mid = count div 2
  let broken = src.replace("  result = zzBig" & $(mid-1) & "(x)\n",
                           "  result = zzBig" & $(mid-1) & "(x\n")
  assert broken != src, "the scale injection changed nothing"

  let rel = "big.nim"
  let above = 3 * (mid - 2) + 1    # body of zzBig(mid-2), ABOVE the injury
  let below = 3 * (mid + 1) + 1    # body of zzBig(mid+2), BELOW it

  var cc = openChecked(src, rel)
  let cleanAbove = cc.ask("textDocument/hover", params(cc.uri, above, 11))
  let cleanBelow = cc.ask("textDocument/definition", params(cc.uri, below, 11))

  var bc = openChecked(broken, rel)
  let gotAbove = bc.ask("textDocument/hover", params(bc.uri, above, 11))
  let gotBelow = bc.ask("textDocument/definition", params(bc.uri, below, 11))
  assert bc.diagnostics > 0, "at scale: the injection produced no diagnostic"

  assert hoverSymbol(gotAbove) == hoverSymbol(cleanAbove),
         "at scale (" & $count & " decls): hover ABOVE the error changed\n  clean:  " &
         cleanAbove & "\n  broken: " & gotAbove
  assert gotBelow.contains("big.nim"),
         "at scale (" & $count & " decls): definition BELOW the error did not " &
         "resolve: " & gotBelow

try:
  checkClean()
  checkAnswersSurvive()
  # 12 and 24 rather than 20 and 120: a full compile of the big module is the
  # single most expensive thing here, and 24 chained declarations is already far
  # enough past a toy fixture to catch a resync that discards the rest of a file.
  for n in [12, 24]:
    checkAtScale(n)
  # A sentinel, because "printed nothing" is indistinguishable between passing and
  # being killed -- which is exactly the ambiguity that made this file's own runs
  # unreadable when the session restarted underneath them.
  writeFile("nimcache" / "lsp" / "broken_queries.ok", "done")
except:
  assert false, "broken-document query test failed"