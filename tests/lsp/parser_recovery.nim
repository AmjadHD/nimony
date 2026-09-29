import std / [assertions, os, strutils, syncio]
import ../../src/nifler2/[nimgrammar, parserrt]

proc checkRecovery(src, laterName: string; rawSpan = "") =
  var p = openParser(src, "parser_recovery.nim", pool, globalTags)
  p.recovering = true
  parseModule p
  assert p.errors.len > 0, "missing recovered diagnostic for: " & src
  assert p.tok.kind == tkEof, "parser did not consume input: " & src
  let buf = finish(p)
  let tree = toString(buf)
  p.close()
  assert tree.contains("(err"), "no err node in: " & tree
  assert tree.contains(laterName), "later declaration lost: " & tree
  if rawSpan.len > 0: assert tree.contains(rawSpan), "bad span was lost: " & tree

proc runFixtures() {.raises.} =
  let fixtures = os.getCurrentDir() / "tests" / "lsp" / "parser_recovery"
  checkRecovery(readFile(fixtures / "unclosed_paren.nim.txt"), "afterParen")
  checkRecovery(readFile(fixtures / "dangling_dot.nim.txt"), "afterDot")
  checkRecovery(readFile(fixtures / "incomplete_let.nim.txt"), "afterLet", "= 1")
  checkRecovery(readFile(fixtures / "truncated_expression.nim.txt"), "value")

try:
  runFixtures()
except:
  assert false, "failed to read parser recovery fixture"
