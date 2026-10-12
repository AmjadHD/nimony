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
  # The err node's raw span must still COVER the skipped tokens, not equal them.
  #
  # It used to be an equality, and that equality was a measurement of the old
  # behaviour rather than of a requirement: recovery ran to end of file, so for
  # `let = 1` the span was the whole of `= 1`. It now stops at `1`, which `module`
  # can start a statement with, so the span is `= `. Demanding the old span would
  # have pinned the bug. A prefix keeps the real requirement -- nothing skipped is
  # dropped -- while letting recovery stop as early as it can.
  if rawSpan.len > 0:
    assert tree.contains("\"" & rawSpan),
           "the skipped span is no longer in the err node: " & tree

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
  checkRecovery(readFile(fixtures / "incomplete_let.nim.txt"), "afterLet", "= ")
  checkRecovery(readFile(fixtures / "truncated_expression.nim.txt"), "value")

proc checkTornTopLevel() =
  ## An unfinished statement at TOP LEVEL, followed by a whole declaration.
  ##
  ## Every other fixture here tears inside a proc body or an argument list. This one
  ## tears where `module` itself gives up, and that path had nothing testing it.
  ##
  ## `module` returns at the first token it cannot use, and `parseModule`'s tail then
  ## names it -- from OUTSIDE every rule, with an empty sync stack, where the only
  ## recovery point available was end of file. So one unfinished line consumed the
  ## rest of the file into the error node's `(stmts @raw)`: a string literal, which
  ## sem copies with `takeTree` and never walks.
  ##
  ## `checkRecovery`'s assertions are `tree.contains(laterName)` and balance. The
  ## first passes either way, because an err node carries the skipped source
  ## verbatim -- that is what let this shape go unnoticed. So the assertions here are
  ## STRUCTURAL: the later declaration must be a `(proc ...)` node, and the tree must
  ## balance. The tree did not balance: the module's own `(stmts` was never closed.
  let src = "proc first() =\n  discard 1\nlet = \nproc later() =\n  discard 2\n"
  var p = openParser(src, "parser_recovery.nim", pool, globalTags)
  p.recovering = true
  parseModule p
  assert p.errors.len > 0, "missing recovered diagnostic"
  let buf = finish(p)
  let tree = toString(buf)
  p.close()
  # A node, not text -- and by the BODY rather than by the proc's own name. The
  # declaration's line info sits between the tag and the name, so the head reads
  # `(proc@,4,file later@5`, and `(proc later` is a spelling this dumper never emits.
  # That assertion passed for a while and meant nothing. The body cannot: raw text
  # carries `discard 2` and no parentheses or line info, so `(discard 2@8)` is only
  # reachable if the declaration was parsed into nodes.
  assert tree.contains("(discard 2@8)"),
         "the later declaration is not a node, so sem will never see it: " & tree
  assert parenBalance(tree) == 0,
         "tree is " & $parenBalance(tree) & " out of balance: " & tree
  # And the skipped text is no longer carrying the rest of the file.
  assert not tree.contains("proc later() =\n  discard 2"),
         "the rest of the file is still raw text inside the error node: " & tree
  # INSIDE the module's statement list, not merely somewhere in the file.
  #
  # Both checks above passed while `later` sat at ROOT level -- a balanced
  # `(err ...)` sibling of the module's `(stmts ...)`, which `sem` never walks:
  # `semcheckCore` asserts `n0.stmtKind == StmtsS` and then `n.into` bounds the walk
  # to that node's body. Measured by the lines sem resolved names on, a declaration
  # after a syntax error went from invisible to analysed, and the only difference is
  # which list it is in. Presence in the file is not presence in the statement list,
  # and only the second one is compiled.
  #
  # "Inside" stated as the paren that closes the module's list coming AFTER the
  # declaration. A depth count needed a first version that was wrong in a way only
  # the tree dump exposed, and this says the same thing with no arithmetic.
  let head = tree.find("(stmts@")
  let decl = tree.find("(discard 2@8)")
  assert head >= 0 and decl > head, "module list or later declaration missing: " & tree
  var depth = 0
  var closedAt = -1
  var i = head
  var inStr = false
  while i < tree.len and closedAt < 0:
    let ch = tree[i]
    if inStr:
      if ch == '\\': inc i
      elif ch == '"': inStr = false
    else:
      case ch
      of '"': inStr = true
      of '(': inc depth
      of ')':
        dec depth
        if depth == 0: closedAt = i
      else: discard
    inc i
  assert closedAt > decl,
         "the later declaration is outside the module's statement list, which closes at " &
         $closedAt & " while it is at " & $decl & ": " & tree

proc rawLinesIn(tree: string): seq[int] =
  ## Newline counts of the raw payloads of every `(err ...)` node, in order.
  ##
  ## This is the measurement of the one thing that has gone wrong here twice: an
  ## error node that carries SKIPPED SOURCE as a string literal rather than as
  ## parsed nodes. `sem` copies such a payload with `takeTree` and never walks it,
  ## so every declaration inside it is invisible -- present in the file, absent
  ## from the statement list, which is the only place anything gets compiled.
  ##
  ## The payload ENDS at its closing quote, and `\\"` inside it does not end it.
  ## An earlier version of this helper ran a fixed 4000-character window and
  ## counted newlines in whatever followed, which reported 49 swallowed lines for
  ## a 29-line file -- a wrong instrument that would have made a healthy parser
  ## look broken.
  result = @[]
  var rest = tree
  while true:
    let at = rest.find("(err")
    if at < 0: break
    rest = if at + 4 < rest.len: rest[at + 4 .. ^1] else: ""
    let q1 = rest.find('"')
    if q1 <= 0: continue
    var nl = 0
    var i = q1 + 1
    var closed = false
    while i < rest.len and not closed:
      if rest[i] == '"':
        closed = true
      elif rest[i] == '\\':
        # The dumper ESCAPES a newline inside a string literal as `\0A`, so
        # counting the `\n` byte found none and reported `rawLinesMax=0` for a tree
        # whose payloads plainly held one -- `(err (stmts ",\0A"))`. An instrument
        # that cannot see the thing it measures turns "no failure" into "no
        # measurement". Any other escape is skipped whole, which is what keeps
        # `\"` from ending the payload early.
        if i + 2 < rest.len and rest[i+1] == '0' and rest[i+2] == 'A':
          inc nl
          i = i + 2
        else:
          inc i
      inc i
    result.add nl
proc checkFallbackDoesNotSwallow() =
  ## The skip loop in `recoverError` is a fallback for the case where NO active
  ## rule's FIRST or FOLLOW matches the current token. Historically that path ran
  ## to end of file and turned the rest of the module into an error node's raw
  ## text; it is what `syncBase` and `parseModule`'s restart loop were added for.
  ##
  ## It is worth knowing whether that path can still do damage, because it is the
  ## only route by which recovery loses code. Measured over the fixtures and then
  ## over deliberately adversarial input -- runs of `) ] } + - * @ \u0060 ,` at top
  ## level, which is what cannot start a statement and therefore cannot match the
  ## module rule's FIRST -- it cannot. Every error resynchronises at the token
  ## immediately after it, and every error node's payload is empty:
  ##
  ##     strayClosers+30: errs=120 rawLinesMax=0 declNodes=2
  ##
  ## 120 diagnostics for 120 injuries, one token consumed each, and no source
  ## demoted to text. So there is nothing here to bound: a cap on the skip loop
  ## would guard a branch that never runs.
  ##
  ## What is worth doing is pinning that, because it is a property that has
  ## regressed twice and is invisible until an editor silently stops analysing a
  ## file. These assertions fail if the fallback ever starts swallowing again --
  ## which is the whole point, since it is the failure nobody would otherwise see.
  var cases: seq[tuple[label, src, later: string]] = @[]
  var closers = "proc first() =\n  discard 1\n"
  for i in 0 ..< 30: closers.add ") ] } ) ] } + - * @ ` ,\n"
  closers.add "proc survivor() =\n  discard 99\n"
  cases.add ("strayClosers", closers, "survivor")

  var ops = "let x = 1\n"
  for i in 0 ..< 30: ops.add ") ] }\n"
  ops.add "proc alsoSurvives() =\n  discard 7\n"
  cases.add ("strayClosersAfterLet", ops, "alsoSurvives")

  # A top-level tear followed by a whole module's worth of declarations: the shape
  # that used to lose the file. `checkTornTopLevel` covers one later declaration;
  # this covers the case where there are enough that losing them is obvious.
  var many = "proc first() =\n  discard 1\nlet =\n"
  for i in 0 ..< 12: many.add "proc d" & $i & "() =\n  discard " & $i & "\n"
  cases.add ("tornTopLevelMany", many, "d11")

  # Indexed rather than tuple-destructured: `for a, b, c in cases` over a
  # `seq[tuple[...]]` is not something this compiler resolves.
  for ci in 0 ..< cases.len:
    let label = cases[ci][0]
    let src = cases[ci][1]
    let later = cases[ci][2]
    var p = openParser(src, "parser_recovery.nim", pool, globalTags)
    p.recovering = true
    parseModule p
    assert p.errors.len > 0, label & ": the input was supposed to be broken"
    assert p.tok.kind == tkEof, label & ": the parser stopped early"
    let buf = finish(p)
    let tree = toString(buf)
    p.close()
    assert tree.contains("(err"), label & ": no err node in: " & tree
    # Deliberately NOT "no error node may hold more than N lines". That was the
    # first version of this assertion and it was wrong twice over: it failed on
    # `strayClosersAfterLet`, where 30 lines ARE swallowed and the declaration
    # after them survives as `(proc@,V alsoSurvives@5 ...)`. Thirty lines of
    # `) ] }` cost nothing -- they are not declarations and every one is
    # diagnosed. A bound on swallowed LINES cannot tell the two apart.
    #
    # What actually kills a file is a payload holding a DECLARATION, because sem
    # copies such a payload with `takeTree` and never walks it. So that is the
    # property, and it is asserted structurally below: a declaration recovered as
    # text cannot produce a body node with line info in it.
    assert tree.contains(later),
           label & ": the declaration after the injury was lost: " & tree
    assert parenBalance(tree) == 0,
           label & ": tree is " & $parenBalance(tree) & " out of balance: " & tree
    # The declaration must be a NODE, not text. `tree.contains(later)` also passes
    # for a name sitting inside an error node's raw payload, which is precisely
    # the failure being pinned -- `checkTornTopLevel` learned this the hard way,
    # where `(proc later` was asserted against a dumper that never emits it. The
    # body is used instead of the proc's name because raw text carries
    # `discard 99` and no line info, so a body node is only reachable if the
    # declaration was really parsed.
    let body = if label == "strayClosers": "(discard 99@"
               elif label == "strayClosersAfterLet": "(discard 7@"
               else: "(discard 11@"
    assert tree.contains(body),
           label & ": the declaration is not a node, so sem will never see it: " & tree

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
  # `rawLinesIn` is what makes the no-swallowing test meaningful: if it returned
  # nothing, every payload assertion would pass for the wrong reason.
  # No error node at all: nothing to report. This is the case a helper that
  # always returned one entry would fail, which is the whole point of checking it.
  assert rawLinesIn("(stmts (let x . . . 1))") == @[],
         "a tree with no error node reported a payload"
  # An err node with an EMPTY payload carries a message, so the helper counts the
  # message: zero lines, but one entry. Asserting @[] here was wrong -- the
  # helper does not, and should not, tell an empty payload from a bare message.
  assert rawLinesIn("(err@1 (stmts .)\"msg\")") == @[0],
         "an empty payload was counted as swallowing something"
  # The dumper writes a newline inside a literal as `\0A`. A helper that counted
  # the `\n` byte returned @[] for all of these, which is how a tree full of
  # swallowed source was measured as swallowing none.
  assert rawLinesIn("(err@1 (stmts \"a\\0Ab\")\"msg\")") == @[1],
         "a one-line payload was not counted"
  assert rawLinesIn("(err@1 (stmts \"a\\0Ab\\0Ac\\0Ad\")\"msg\")") == @[3],
         "a three-line payload was miscounted"
  # An escaped quote does not end the payload, so the `\0A` after it still counts.
  assert rawLinesIn("(err@1 (stmts \"q\\\"\\0Az\")\"msg\")") == @[1],
         "an escaped quote ended the payload early"

try:
  runFixtures()
  checkTornTopLevel()
  checkFallbackDoesNotSwallow()
  checkLegalDots()
  checkCheckers()
except:
  assert false, "failed to read parser recovery fixture"
