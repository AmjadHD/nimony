## Which object shapes complete, through the editor rather than the sidecar.
##
## `tests/lsp/members.nim` reads the sidecar, so it proves sem produced the right
## `dotMembers` rows. It says nothing about whether the editor turns those rows
## into a completion -- and those are two readers that have drifted apart before.
## This drives `handle` directly, which is the path a user's keystroke takes.

import std / [assertions, os, strutils, syncio, uri, envvars]
import ../../src/lsp / [database, handlers]

proc escape(s: string): string =
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    else: result.add ch

proc labels(response: string): seq[string] =
  result = @[]
  var i = 0
  while i < response.len:
    let a = response.find("\"label\":\"", i)
    if a < 0: break
    var j = a + 9
    var name = ""
    while j < response.len and response[j] != '"':
      name.add response[j]
      inc j
    result.add name
    i = j

proc probe(label, text: string; line, col: int) {.raises.} =
  var db = initDatabase(getCurrentDir())
  let uriText = "file://" & getCurrentDir() / "nimcache" / "lsp" / "obj.nim"
  discard handle(db, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & uriText & "\",\"version\":1," &
    "\"text\":\"" & escape(text) & "\"}}}")
  let r = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/completion\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & uriText & "\"}," &
    "\"position\":{\"line\":" & $line & ",\"character\":" & $col & "}}}")
  stdout.writeLine label & ": [" & labels(r.response).join(", ") & "]"

proc run() {.raises.} =
  ## `head` is 8 lines (2 decls of 3 and 5), so `proc use...` is line 9 and the
  ## access is line 10. The earlier revision said 9, which put the cursor inside
  ## `proc use` -- on the identifier `use`, with no dot anywhere near it. Every
  ## result it printed was answering a different question than the label claimed.
  let head = "type Inner = object\n  deep*: int\n\n" &
             "type Outer = object\n  alpha*: int\n  beta: string\n  inner*: Inner\n\n"
  #        0-based: the dot is the 3rd char of `  o.a`, so the cursor sits at 4
  #        (on the name) or 3 (right after the dot).
  probe("param",            head & "proc use(o: Outer) =\n  o.a\n", 9, 4)
  probe("local let",        head & "proc use() =\n  let o = Outer()\n  o.a\n", 10, 4)
  probe("local var",        head & "proc use() =\n  var o = Outer()\n  o.a\n", 10, 4)
  probe("seq element",      head & "proc use(s: seq[Outer]) =\n  s[0].a\n", 9, 7)
  probe("ref deref",        head & "proc use(o: ref Outer) =\n  o.a\n", 9, 4)
  probe("nested, no partial", head & "proc use(o: Outer) =\n  o.inner.\n", 9, 9)
  probe("nested, partial",  head & "proc use(o: Outer) =\n  o.inner.d\n", 9, 10)
  # Two dots, cursor on the FIRST dot's member: the receiver there is `o`, so
  # Outer's fields are the right answer even though a later dot also qualifies.
  probe("two dots, first",  head & "proc use(o: Outer) =\n  o.in\n", 9, 4)

proc main() {.raises.} =
  run()

try:
  main()
except:
  stderr.writeLine "objprobe raised"