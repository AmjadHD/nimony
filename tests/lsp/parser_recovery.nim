import std / [assertions, os, strutils, syncio]
import ../../src/nifler2/[nimgrammar, nimlexer, parserrt]

proc parenBalance(tree: string): int =
  ## Depth reached scanning `tree`, counting `(` and `)` and skipping string
  ## literals, so a bracket inside a message or an err node's raw text does not
  ## count. Negative means a close arrived with nothing open.
  ##
  ## One advance per iteration, and a `\` inside a string swallows the character
  ## after it. Advancing twice for a string -- once past the closing quote, then
  ## once more for the loop -- skips whatever follows, and since an err node puts
  ## its message last, that is a `)` every time. It reads as a tree one construct
  ## short of closing, which is a bug in the checker rather than in the parser.
  result = 0
  var i = 0
  var inStr = false
  while i < tree.len:
    let ch = tree[i]
    if inStr:
      if ch == '\\': inc i
      elif ch == '"': inStr = false
    else:
      case ch
      of '"': inStr = true
      of '(': inc result
      of ')': dec result
      else: discard
    inc i

proc contentTokens(src: string): seq[string] =
  ## The source's identifiers and numbers: what a reader would expect to find in
  ## the tree afterwards. Keywords and operators are grammar rather than content,
  ## and an err node is free to drop either -- what it may not do is lose a name
  ## the author wrote. Lexed with the project's own lexer rather than a pattern,
  ## so a name inside a comment is not mistaken for one.
  ##
  ## Numbers only up to `tkFloat128Lit`: the string and char kinds follow it in
  ## the same enum, and a literal's *contents* are not a name the author wrote, so
  ## ranging to `tkCustomLit` would demand that a swallowed string literal show up
  ## as one.
  result = @[]
  var lex = openLexer(src)
  var tok = Token(kind: tkInvalid, s: "", indent: -1, spacing: {},
                 line: 0, col: 0, base: 10, suffixPos: -1)
  next lex, tok
  while tok.kind != tkEof:
    if tok.kind == tkSymbol or (tok.kind >= tkIntLit and tok.kind <= tkFloat128Lit):
      if tok.s.len > 0: result.add tok.s
    next lex, tok

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

  # Every opened construct closes, even through an error node. This is the
  # property Phase 2v1 rests on: it walks the tree, so a single missing ParRi
  # makes everything downstream of the error unreadable rather than merely wrong.
  # It is checked by counting, not by looking for a marker, because a tree that
  # happens to contain "ParRi" is not a balanced tree.
  let depth = parenBalance(tree)
  assert depth == 0, "tree is " & $depth & " out of balance in: " & tree

  # Every byte of the source is represented. An err node carries the span it
  # resynced past as raw text, so a run that recovery had to swallow still shows
  # up; what must never happen is a name vanishing, which is what a resync that
  # drops input looks like.
  for token in contentTokens(src):
    assert tree.contains(token),
           "source token lost from the tree: " & token & " in: " & tree

proc runFixtures() {.raises.} =
  let fixtures = os.getCurrentDir() / "tests" / "lsp" / "parser_recovery"
  checkRecovery(readFile(fixtures / "unclosed_paren.nim.txt"), "afterParen")
  checkRecovery(readFile(fixtures / "dangling_dot.nim.txt"), "afterDot")
  checkRecovery(readFile(fixtures / "dangling_dot_before_proc.nim.txt"), "other")
  checkRecovery(readFile(fixtures / "incomplete_let.nim.txt"), "afterLet", "= 1")
  checkRecovery(readFile(fixtures / "truncated_expression.nim.txt"), "value")

proc checkLegalDots() =
  ## A dot's field name may be a keyword -- `a.and`, `a.type`, `a.import` are all
  ## real accesses -- so the guard that stops a dangling dot from eating the next
  ## declaration has to be narrow. It reads "a declaration keyword with a name
  ## behind it", and the two halves fail separately:
  ##
  ## * `a.type` alone, or followed by another statement on the next line, must stay
  ##   a field access. Reaching the name may not cross a newline: skipping one made
  ##   `let y = a.type` + `let z = 1` read as a `type` declaration named `let`, and
  ##   rejected a legal `a.type`.
  ## * `a.import` with nothing behind it must stay a field access too -- there is no
  ##   name, so there is no declaration.
  for src in ["let x = a.and\n", "let y = a.type\n", "let z = a.addr\n",
              "let w = a.import\n", "let v = a.type\nlet u = 1\n"]:
    var p = openParser(src, "parser_recovery.nim", pool, globalTags)
    p.recovering = true
    parseModule p
    let tree = toString(finish(p))
    p.close()
    assert p.errors.len == 0,
           "a legal keyword field access was rejected: " & src & " -> " & tree
    assert tree.contains("(dot"),
           "the field access did not survive: " & src & " -> " & tree

proc checkCheckers() =
  ## The two checks above are only worth having if they reject what they should,
  ## so each is exercised on input that must fail. Without this a helper that
  ## silently returned a constant would leave the corpus green.
  assert parenBalance("(a (b) c)") == 0
  assert parenBalance("(a (b) c") == 1, "an unclosed construct went unnoticed"
  assert parenBalance(")") == -1, "a close with nothing open went unnoticed"
  # A close immediately after a string: an err node puts its message last, so
  # this is the shape every recovered tree ends in.
  assert parenBalance("(a \"msg\")") == 0,
         "a close straight after a string went uncounted"
  # A bracket inside text is part of the text, not of the structure.
  assert parenBalance("(a \"(\")") == 0, "a bracket inside a string was counted"
  assert parenBalance("(a \"x\\\"(\")") == 0,
         "an escaped quote ended the string early"
  assert contentTokens("let x = 1\n") == @["x", "1"]
  assert contentTokens("proc foo(): int =\n  42\n") == @["foo", "int", "42"]
  assert contentTokens("# hiddenName\nlet kept = 1\n") == @["kept", "1"],
         "a name inside a comment was treated as content"
  assert contentTokens("let s = \"inside\"\n") == @["s"],
         "a string literal's contents were treated as a name"

try:
  runFixtures()
  checkLegalDots()
  checkCheckers()
except:
  assert false, "failed to read parser recovery fixture"
