## A member completion must not cost the whole scope chain to compute.
##
## `captureIdeName` used to walk every visible name on every cursor query. For a
## member completion that list is never read -- the answer is the dot's own rows
## -- so the walk was pure cost: ~4144ms per member query on handlers.nim against
## ~163ms with it skipped, a 25x difference spent building a discarded list.
##
## Skipping only `visible` and not `candidates` is the part that matters. A cursor
## on a member name satisfies the member test just as a half-typed one does, and
## hover and definition both read `candidates`, so a coarser skip blanked them for
## any document whose document-mode compile recorded nothing.
##
## This reads the sidecar rather than going through the editor, because the editor
## masks exactly that: for an opened document hover answers from the recorded
## occurrences and never runs a cursor compile, which is why the suite stayed green
## while the coarser skip was wrong.
##
## A cursor on a completed member name rather than a half-typed one: the member
## test is lexical, so both are the same request, and a file ending in an
## incomplete dot is the parser recovery question rather than this one.

import std / [assertions, os, strutils, syncio, osproc]

# Relative, and matching what the compiler records for the module. Pass an absolute
# path for `--visible:` and the cursor stops matching: `captureIdeName` compares the
# identifier's file against the query's own, and the two spellings are different
# symbols. The editor is unaffected -- it derives both from one path.
const module = "tests" / "lsp" / "fixtures" / "dotprobe.nim"

# A private cache. The suite's other LSP tests share `nimcache/lsp`, and wiping it
# from under them would be a race rather than a test. Not `getTempDir()`: it is not
# writable here.
let cache = "nimcache" / "lsp-dotprobe"

proc sidecar(): string {.raises.} =
  ## The ide sidecar is named after a hash of the module path, so it cannot be
  ## addressed by name, and this stdlib has no directory walk to find it with. The
  ## caller wipes the cache first, so listing it finds the one file.
  var found = 0
  var name = ""
  let (listing, _) = execCmdEx("ls " & cache)
  for entry in listing.splitLines:
    if entry.endsWith(".ide.tsv"):
      inc found
      name = entry
  assert found == 1,
         "expected one ide sidecar in " & cache & ", found " & $found
  result = cache / name

proc rowsFor(tag: string): seq[string] {.raises.} =
  ## `lines` is not usable once `osproc` is in scope -- it has a Process overload
  ## that wins the name.
  result = @[]
  let text = readFile(sidecar())
  for line in text.splitLines:
    if line.startsWith(tag & "\t"): result.add line

proc runTests() {.raises.} =
  writeFile(module, "type Color = enum\n  colRed, colGreen\n\n" &
                    "proc use(s: string) =\n  discard s.len\n\n" &
                    "proc partial(k: Color) =\n  discard k\n  Color.colRed\n  k.colRed\n")

  # Three cursors, all inside a member name that follows a dot, so all three are
  # member requests by the lexical rule. Nothing but the position distinguishes
  # them, which is why the editor cannot be the thing that tells them apart.
  #
  # The two enum rows are the point. `Color.colRed` is real Nim -- a qualified
  # access, resolved in `tryBuiltinDot`'s `TypeddescT` branch -- so that dot has
  # two members. `k.colRed` is an error: an enum *value* has no fields, so it has
  # none. Offering the literals for both is what produced a completion that did
  # not compile.
  let positions = [("qualified `Color.colRed`", 9, 9, 2),
                   ("value `k.colRed`", 10, 5, 0),
                   ("`s.len`", 5, 13, 0)]
  for (label, line, col, wantDotMembers) in positions:
    discard execCmdEx("rm -rf " & cache)
    # 1-based, as the LSP spells it and as `cursorCompletesMember` reads it.
    discard execCmdEx("bin/nimony --nimcache:" & cache & " check " & module &
                      " --visible:" & module & "," & $line & "," & $col &
                      " >/dev/null 2>&1")
    let dotRows = rowsFor("dotmember")
    let candidateRows = rowsFor("candidate")
    let visibleRows = rowsFor("visible")
    echo label, ": dotmember=", dotRows.len,
         " candidate=", candidateRows.len, " visible=", visibleRows.len
    # The ~4s: a walk over every visible name that no member query can use.
    assert visibleRows.len == 0,
           label & " walked the scope chain anyway: " & $visibleRows.len &
           " rows, and that walk is the ~4s"
    assert dotRows.len == wantDotMembers,
           label & " recorded " & $dotRows.len & " members, expected " &
           $wantDotMembers
    # The coarse skip would have taken `s.len` with it: it is a member request by
    # position, which still needs the name under the cursor resolved.
    if wantDotMembers == 0:
      assert candidateRows.len > 0,
             label & " lost the name under the cursor: no candidate was resolved"

  discard execCmdEx("rm -rf " & cache & " " & module)
  echo "dotprobe: ok"

try:
  runTests()
except:
  assert false, "dotprobe raised unexpectedly"