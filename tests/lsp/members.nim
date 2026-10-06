## A dot's members: the fields of the receiver's type, and what must stay out.
##
## Enums were the first thing offered here and they were wrong -- `k.` for
## `k: Color` suggested `colRed`, which does not compile, because an enum *value*
## has no fields. What is offered now is a field list, which means the rules that
## decide one all matter:
##
## * ownership -- a `ref` is one dereference away, and the list has to follow it;
## * visibility -- a private field is not reachable from another module, so
##   offering it is the same kind of wrong the enum literals were;
## * inheritance -- nimony rejects `object of` outright, so a derived type really
##   does have nothing but its own fields, and offering a base's would be a
##   suggestion that does not compile.
##
## The last one is why there is no derived-type case here. It would have to assert
## that inherited fields are *absent*, which is only true because inheritance is
## unimplemented -- the day it lands, this test is wrong rather than incomplete.
##
## This reads the sidecar rather than going through the editor: the sidecar is
## where the rows are, and the editor only reshapes them.

import std / [assertions, os, strutils, syncio, osproc]

# Relative, and matching what the compiler records for the module. An absolute
# path for `--visible:` stops the cursor matching, because `captureIdeName`
# compares the identifier's file against the query's own and the two spellings are
# different symbols.
const fixtureDir = "tests" / "lsp" / "fixtures"

# A private cache. The suite's other LSP tests share `nimcache/lsp`, and wiping it
# from under them would be a race rather than a test.
let cache = "nimcache" / "lsp-members"

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

proc members(): seq[string] {.raises.} =
  ## `lines` is not usable once `osproc` is in scope -- it has a Process overload
  ## that wins the name.
  result = @[]
  let text = readFile(sidecar())
  for line in text.splitLines:
    if line.startsWith("dotmember\t"): result.add line.split('\t')[1]

proc check(label, module, text: string; line, col: int; want: seq[string]) {.raises.} =
  writeFile(module, text)
  discard execCmdEx("rm -rf " & cache)
  # Complete member accesses, not a dangling dot: the CLI parses without recovery,
  # so `o.` at end of file never reaches sem. `--path:` is what makes the
  # cross-module case resolve.
  discard execCmdEx("bin/nimony --nimcache:" & cache & " --path:" & fixtureDir &
                    " check " & module &
                    " --visible:" & module & "," & $line & "," & $col &
                    " >/dev/null 2>&1")
  let got = members()
  assert got == want,
         label & ": got [" & got.join(", ") & "], expected [" & want.join(", ") & "]"

proc runTests() {.raises.} =
  let module = fixtureDir / "members.nim"
  let helper = fixtureDir / "members_helper.nim"

  writeFile(helper, "type Exported* = object\n  pub*: int\n  priv: int\n")

  check("a private field is reachable in its own module", module,
        "type Plain = object\n  a*: int\n  b: int\n\n" &
        "proc use(o: Plain) =\n  o.a\n",
        6, 5, @["a", "b"])

  check("the same fields through a ref", module,
        "type Plain = object\n  a*: int\n  b: int\n\n" &
        "proc use(o: ref Plain) =\n  o.a\n",
        6, 5, @["a", "b"])

  # The cross-module case, which is where visibility earns its keep. `priv` is not
  # reachable from here, so listing it would suggest code that does not compile --
  # nimony agrees, and reports "undeclared field: 'priv' for type Exported" for
  # the same access.
  #
  # The type is named unqualified. nimony cannot resolve a type through a module
  # qualifier -- `members_helper.Exported` is "undeclared identifier in module" --
  # so that spelling would test nothing but that gap.
  check("only the exported field from another module", module,
        "import members_helper\n\n" &
        "proc use(o: Exported) =\n  discard o.pub\n",
        4, 13, @["pub"])

  # An enum value has no fields at all; the enum *type* has its literals, which are
  # a qualified access. Both halves, because they were once the same code path.
  check("an enum value has no members", module,
        "type Color = enum\n  colRed, colGreen\n\n" &
        "proc use(k: Color) =\n  discard k.colRed\n",
        5, 13, @[])

  check("the enum type has its literals", module,
        "type Color = enum\n  colRed, colGreen\n\n" &
        "proc use(k: Color) =\n  discard k\n  Color.colRed\n",
        6, 9, @["colRed", "colGreen"])

  discard execCmdEx("rm -rf " & cache & " " & module & " " & helper)
  echo "members: ok"

try:
  runTests()
except:
  assert false, "members raised unexpectedly"