## Per-document syntax database for the LSP. Syntax records are token/node
## granular; semantic name visibility is rebuilt for the containing document.

{.feature: "lenientnils".}

import std / [tables, strutils, os, hashes, dirs, paths, syncio, osproc, envvars]
import ../nifler2 / [nimgrammar, nimlexer, parserrt]
import ../nifler2 / niflerout
import ../lib / comesfrom
import ../gear2 / modnames
import ../lib / nifpools
import ../nimony / [semmain, semdata, nifconfig, semos, builtintypes]

type
  SourceRange* = object
    startLine*, startCharacter*, endLine*, endCharacter*: int

  SyntaxNode* = object
    id*: int
    text*: string
    range*: SourceRange
    startOffset*, endOffset*: int
    scope*: int
    declarationKind*: string

  ScopeNode* = object
    id*, parent*, indent*: int

  SemanticSymbol* = object
    name*, kind*, uri*, doc*: string
    range*: SourceRange

  IdePosition* = object
    ## One identifier occurrence and what it resolved to, from document mode.
    ## The editor indexes these by position so no query needs a new compile.
    line*, column*: int
    name*: string
    symbols*: seq[SemanticSymbol]

  SemanticSnapshot* = object
    queried*, matched*, documentMode*: bool
    visible*, candidates*, imports*: seq[SemanticSymbol]
    ## A dot's members, kept apart from `visible` because that is the whole scope
    ## chain and sem writes both when the cursor is on a half-typed member.
    dotMembers*: seq[SemanticSymbol]
    ## The overloads the cursor's call could still resolve to. Empty unless a
    ## cursor query landed mid-call, and a first-class "no result" otherwise.
    signatures*: seq[SemanticSignature]
    positions*: seq[IdePosition]

  SemanticSignature* = object
    ## One surviving overload of the call the cursor is inside, with its parameter
    ## *types*. No names: they need the `CallArg` widening, deliberately not done.
    name*, kind*, params*: string

  Document* = ref object
    uri*, path*: string
    workspaceRoot*: string
    version*: int
    text*: string
    nodes*: seq[SyntaxNode]
    scopes*: seq[ScopeNode]
    diagnostics*: seq[ParseDiagnostic]       ## from the recovering parser
    semanticDiagnostics*: seq[ParseDiagnostic] ## from the compiler's sem pass
    snapshot*: SemanticSnapshot  ## every identifier occurrence, from one check
    nifTree*: string
    docComments*: Table[int, string]
      ## `##` documentation keyed by the line the block ends on, as the parser
      ## recorded it -- not re-scanned from the text
    cacheFile*: string
    parsedFile*: string
    moduleName*: string
    queryCached*: bool
    queryLine*, queryCharacter*: int
    queryResult*: SemanticSnapshot

  Database* = object
    root*, cacheDir*: string
    documents*: Table[string, Document]

const DeclKeywords = ["let", "var", "const", "type", "proc", "func",
                      "iterator", "template", "macro", "method", "converter"]

proc compilerRoot(db: Database): string =
  var dir = os.getAppDir()
  for _ in 0 .. 7:
    if os.fileExists(dir / "nimony"):
      return if os.splitPath(dir).tail == "bin": os.parentDir(dir) else: dir
    if os.fileExists(dir / "bin" / "nimony"): return dir
    let parent = os.parentDir(dir)
    if parent == dir: break
    dir = parent
  result = db.root

proc modulePaths(db: Database): seq[string] =
  let compilerRoot = db.compilerRoot
  @[db.root, compilerRoot / "lib", compilerRoot / "src" / "lib"]

proc initDatabase*(root: string): Database {.raises.} =
  let actualRoot = if root.len > 0: root else: os.getCurrentDir()
  result = Database(root: actualRoot, cacheDir: actualRoot / "nimcache" / "lsp",
                     documents: initTable[string, Document]())
  try:
    createDir(path(result.cacheDir))
  except:
    discard

proc isIdentStart(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z', '_'} or ord(c) >= 0x80

proc isIdentContinue(c: char): bool {.inline.} =
  isIdentStart(c) or c in {'0'..'9'}

proc utf16Width(c: char): int {.inline.} =
  let b = ord(c)
  if b in 0x80..0xBF: 0
  elif b >= 0xF0: 2
  else: 1

proc addNode(doc: var Document; text: string; startOffset, endOffset,
             line, character, characterWidth, scope: int;
             declarationKind: string) =
  doc.nodes.add SyntaxNode(id: doc.nodes.len, text: text,
    range: SourceRange(startLine: line, startCharacter: character,
                       endLine: line, endCharacter: character + characterWidth),
    startOffset: startOffset, endOffset: endOffset, scope: scope,
    declarationKind: declarationKind)

proc indexSyntax(doc: var Document) =
  doc.nodes.setLen(0)
  doc.scopes = @[ScopeNode(id: 0, parent: -1, indent: 0)]
  var i = 0
  var line = 0
  var col = 0
  var lineIndent = 0
  var atLineStart = true
  var previous = ""
  var declarationKind = ""
  var expectingName = false
  var declarationList = false

  while i < doc.text.len:
    let ch = doc.text[i]
    if ch == '\n':
      inc line
      inc i
      col = 0
      atLineStart = true
      lineIndent = 0
      previous = ""
      declarationKind = ""
      expectingName = false
      declarationList = false
      continue
    if ch in {' ', '\t', '\r'}:
      if atLineStart:
        lineIndent += (if ch == '\t': 2 else: 1)
      inc col
      inc i
      continue
    if atLineStart:
      while doc.scopes.len > 1 and lineIndent < doc.scopes[^1].indent:
        doc.scopes.setLen(doc.scopes.len - 1)
      if lineIndent > doc.scopes[^1].indent:
        doc.scopes.add ScopeNode(id: doc.scopes.len,
          parent: doc.scopes[^1].id, indent: lineIndent)
      atLineStart = false
      lineIndent = 0
    if ch == '#':
      while i < doc.text.len and doc.text[i] != '\n':
        col += utf16Width(doc.text[i])
        inc i
      continue
    if ch in {'"', '\''}:
      let quote = ch
      inc i
      inc col
      while i < doc.text.len:
        if doc.text[i] == '\\' and i + 1 < doc.text.len:
          i += 2
          col += 2
        elif doc.text[i] == quote:
          inc i
          inc col
          break
        elif doc.text[i] == '\n':
          inc line
          inc i
          col = 0
          atLineStart = true
          break
        else:
          col += utf16Width(doc.text[i])
          inc i
      previous = "literal"
      continue
    if isIdentStart(ch):
      let start = i
      let startCol = col
      while i < doc.text.len and isIdentContinue(doc.text[i]):
        col += utf16Width(doc.text[i])
        inc i
      let word = doc.text.substr(start, i - 1)
      var kind = ""
      if previous in DeclKeywords:
        kind = previous
        declarationKind = previous
        expectingName = false
        declarationList = previous in ["let", "var", "const", "type"]
      elif expectingName:
        kind = declarationKind
        expectingName = false
      elif declarationList and previous == ",":
        kind = declarationKind
      doc.addNode(word, start, i, line, startCol, col - startCol,
                  doc.scopes[^1].id, kind)
      if word in DeclKeywords:
        declarationKind = word
        expectingName = true
        declarationList = word in ["let", "var", "const", "type"]
      previous = word
      continue
    if ch in {'=', ':'} and declarationList:
      declarationList = false
      expectingName = false
    elif ch == ',' and declarationList:
      previous = ","
    else:
      previous = $ch
    col += utf16Width(ch)
    inc i

proc correctPositionColumns(doc: var Document) {.raises.} =
  ## NIF line info for a `dot` expression's field points at the operator rather
  ## than at the name (`node.c` records the column of `e`, the end of `node`),
  ## so a recorded column can be off by one or more. Each column is snapped to
  ## the name on that line once here, rather than on every query. A column that
  ## already holds the name is left alone, and one that finds nothing is left
  ## alone too -- a wrong guess would be worse than none.
  let lines = doc.lineText
  if lines.len == 0: return
  for id in 0 ..< doc.snapshot.positions.len:
    let position = doc.snapshot.positions[id]
    if position.name.len == 0: continue
    var index = position.line - 1
    if index < 0 or index >= lines.len: continue
    let line = lines[index]
    if position.column >= 0 and position.column + position.name.len <= line.len and
        line.substr(position.column, position.column + position.name.len - 1) == position.name:
      continue
    var found = -1
    var start = max(0, position.column)
    while start + position.name.len <= line.len:
      if line.substr(start, start + position.name.len - 1) == position.name and
          (start == 0 or not isIdentContinue(line[start - 1])) and
          (start + position.name.len == line.len or
              not isIdentContinue(line[start + position.name.len])):
        found = start
        break
      inc start
    if found >= 0:
      doc.snapshot.positions[id].column = found

proc lineText(doc: Document): seq[string] {.raises.} =
  ## The document split into lines, so a position's column can be snapped to
  ## the name on its line.
  doc.text.splitLines

proc runDiagnostics*(db: var Database; doc: var Document) {.raises.} =
  ## One check per document version, in document mode: every identifier
  ## occurrence, the import table and the errors together. Queries then read
  ## this instead of compiling again, so the cost lands on the edit rather than
  ## on every cursor move.
  doc.queryLine = -1
  doc.queryCharacter = -1
  if semInProcess() and db.dependencyClosureReady(doc):
    try:
      let res = db.runSemInProcess(doc, -1, -1)
      doc.snapshot = snapshotFromQuery(doc, res, -1, -1)
      correctPositionColumns(doc)
      # Errors still come from the sidecar, which in-process sem still writes.
      # That is the honest state of this: the query travels as a struct, the
      # diagnostics do not yet, and pretending otherwise would mean reading a
      # file this path no longer needs for the query -- reintroducing the
      # dependency it was meant to remove.
      doc.semanticDiagnostics = semanticErrors(sidecarFor(db, doc))
      return
    except:
      # Falling back rather than reporting: the subprocess path is slower but
      # proven, and a query is worth more than an explanation of why it could
      # not be answered. The reason goes to stderr, which is the only channel
      # here -- stdout is the JSON-RPC transport.
      # The exception's message is not reachable from a bare `except` in this
      # stdlib, so the fallback reason is logged without it. stderr, because
      # stdout is the JSON-RPC transport.
      stderr.writeLine "[nimony-lsp] in-process sem failed, falling back to the subprocess"
  let content = db.runCompiler(doc)
  doc.snapshot = parseIdeSnapshot(doc, content.sidecar, -1, -1)
  correctPositionColumns(doc)
  doc.semanticDiagnostics = semanticErrors(content.sidecar)
  # A compile that failed is not a file without errors. Reporting it as clean is
  # what turns a build problem into an editor that looks broken, so the failure
  # is surfaced in place rather than swallowed.
  if content.failure.len > 0:
    doc.semanticDiagnostics.add ParseDiagnostic(line: 0, col: 0,
      message: "semantic analysis failed: " & content.failure)

proc updateDocument*(db: var Database; uri, path: string; version: int;
                     text: string): Document {.raises.} =
  var doc = Document(uri: uri, path: path, workspaceRoot: db.root,
                     version: version, text: text)
  var p = openParser(text, path, pool, globalTags)
  p.recovering = true
  # Only the editor wants the `##` text: batch parsing leaves the tree exactly
  # as it was, and the language server is the only caller that sets this.
  p.keepComments = true
  parseModule p
  doc.docComments = p.docComments
  doc.diagnostics = p.errors
  let tree = finish(p)
  doc.nifTree = toString(tree)
  doc.indexSyntax()
  let key = $hash(uri)
  doc.cacheFile = db.cacheDir / (key & ".nif")
  doc.moduleName = moduleSuffix(path, db.modulePaths)
  doc.parsedFile = db.cacheDir / (doc.moduleName & ".p.nif")
  writeNifler(p.first, p.pool, p.tags, cellCount(p.arena) * 8,
              doc.parsedFile, path)
  writeDeps(p.first, p.pool, p.tags,
            db.cacheDir / (doc.moduleName & ".p.deps.nif"))
  p.close()
  try:
    writeFile(doc.cacheFile, doc.nifTree)
  except:
    discard
  db.documents[uri] = doc
  result = doc

proc closeDocument*(db: var Database; uri: string) {.raises.} =
  if db.documents.hasKey(uri):
    let cacheFile = db.documents.getOrDefault(uri).cacheFile
    let parsedFile = db.documents.getOrDefault(uri).parsedFile
    let depsFile = db.cacheDir / (db.documents.getOrDefault(uri).moduleName & ".p.deps.nif")
    let ideFile = db.cacheDir / (db.documents.getOrDefault(uri).moduleName & ".ide.tsv")
    let semFile = db.cacheDir / (db.documents.getOrDefault(uri).moduleName & ".s.nif")
    try:
      if os.fileExists(cacheFile): removeFile(path(cacheFile))
      if os.fileExists(parsedFile): removeFile(path(parsedFile))
      if os.fileExists(depsFile): removeFile(path(depsFile))
      if os.fileExists(ideFile): removeFile(path(ideFile))
      if os.fileExists(semFile): removeFile(path(semFile))
    except:
      discard
    db.documents.del(uri)

proc document*(db: Database; uri: string): Document {.raises.} =
  db.documents.getOrDefault(uri)

proc positionAt*(snapshot: SemanticSnapshot; line, character: int): IdePosition {.raises.} =
  ## The occurrence the cursor is inside, if any. An identifier can be several
  ## columns wide, so the match is by span and not by the exact start column.
  ##
  ## One span can carry two records. When a name resolved through overload
  ## resolution, sem reports both the overload set it weighed and the single
  ## symbol it picked -- and the set comes first, so taking the first match
  ## returned the set's first element rather than the answer. For `result.add`
  ## on a `string` that is `seqimpl.add` instead of `stringimpl.add`, so hover
  ## described the wrong proc and quoted the wrong comment. A record with one
  ## candidate is a resolution and outranks an overload set, whatever the column.
  result = IdePosition(line: -1, column: -1)
  var bestRank = 0
  var bestDistance = high(int)
  for position in snapshot.positions:
    if position.line != line + 1: continue
    let width = position.name.len
    if character < position.column or character >= position.column + width: continue
    let distance = character - position.column
    let rank = if position.symbols.len == 1: 2 elif position.symbols.len > 1: 1 else: 0
    if rank < bestRank: continue
    if rank == bestRank and distance >= bestDistance: continue
    bestRank = rank
    bestDistance = distance
    result = position
  result

proc unescapeTsv(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 't': result.add '\t'
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      else: result.add s[i + 1]
      i += 2
    else:
      result.add s[i]
      inc i

proc moduleNameForPath*(db: Database; path: string): string =
  moduleSuffix(path, db.modulePaths)

proc firstErrorLine(output: string): string =
  ## The compiler's own first complaint, so a log line explains the failure
  ## instead of just its exit code. nifmake wraps the real error in
  ## `[Error] ...`, which is the line worth keeping.
  for line in output.splitLines:
    if line.strip.len > 0:
      return line.strip
  ""

proc sidecarFor(db: Database; doc: Document): string =
  ## The sidecar `writeIdeQuery` wrote for this document, or the empty string.
  ## Named because three callers now want it, and inlining the path three times
  ## is how a rename leaves one behind.
  result = ""
  let f = db.cacheDir / (doc.moduleName & ".ide.tsv")
  if os.fileExists(f):
    # A missing or unreadable sidecar is the empty string, not a raise: the
    # caller treats empty as "no query recorded", which is the right answer for a
    # document sem has not run on. Reporting it as an error would turn a normal
    # editor state into a broken one.
    try: result = readFile(f)
    except: discard

proc runCompiler*(db: Database; doc: Document): tuple[sidecar: string,
                                                       failure: string] {.raises.} =
  ## Run sem for `doc` and return its sidecar. Both the semantic query and the
  ## diagnostics come out of this one invocation, so a query never costs a
  ## second compile. `failure` is non-empty when the compiler did not produce a
  ## usable result, which the caller must not confuse with "no errors".
  result = (sidecar: "", failure: "")
  let compiler = db.compilerRoot / "bin" / "nimony"
  let ideFile = db.cacheDir / (doc.moduleName & ".ide.tsv")
  let semFile = db.cacheDir / (doc.moduleName & ".s.nif")
  try:
    if os.fileExists(semFile): removeFile(path(semFile))
    if os.fileExists(ideFile): removeFile(path(ideFile))
  except:
    discard
  var command = quoteShell(compiler) & " --base:" & quoteShell(db.root) &
    " --nimcache:" & quoteShell(db.cacheDir)
  # The root handed to sem is a pre-parsed `.nif` under the cache dir, so its
  # own directory is the cache dir rather than the source tree. A `./`-less
  # sibling import (`import database`) is resolved against the *importing
  # file's* directory, so without the open document's directory on the search
  # path such a module resolves to nothing: nimony creates the node with no
  # parse rule and the build dies with `cannot open: <mod>.s.nif`. That is the
  # whole reason a file importing its siblings failed while an identical file
  # importing only `std` worked. The path is added here rather than in
  # `modulePaths` because that one feeds `moduleSuffix`, and widening it would
  # change module names for files that already work.
  let docDir = parentDir(doc.path)
  if docDir.len > 0:
    command.add " --path:" & quoteShell(docDir)
  for searchPath in db.modulePaths:
    command.add " --path:" & quoteShell(searchPath)
  command.add " check " & quoteShell(doc.parsedFile)
  # The sidecar is written either way: with a cursor it carries the query,
  # without one the errors alone. Line 0 is not a source line, so a
  # cursor-less run collects diagnostics and matches no name.
  var track = doc.path & ",0,0"
  if doc.queryLine >= 0:
    let offset = doc.positionOffset(doc.queryLine, doc.queryCharacter)
    var lineStart = offset
    while lineStart > 0 and doc.text[lineStart - 1] != '\n': dec lineStart
    track = doc.path & "," & $(doc.queryLine + 1) & "," & $(offset - lineStart + 1)
  command.add " --visible:" & quoteShell(track)
  # `execCmdEx` reports failure through its exit code and does not raise, so a
  # compile that died would otherwise be indistinguishable from a clean run with
  # no errors. That is the worst possible failure for an editor: it clears the
  # diagnostics and answers every query from an empty snapshot, so the file
  # simply "stops working" for reasons the user cannot see. A failed run must
  # say so.
  let (output, exitCode) = execCmdEx(command, workingDir = db.root)
  if exitCode != 0:
    stderr.writeLine "[nimony-lsp] compile failed (exit " & $exitCode & ") for " &
      doc.path
    stderr.writeLine "[nimony-lsp] " & firstErrorLine(output)
  if os.fileExists(ideFile):
    result.sidecar = readFile(ideFile)
  if exitCode != 0:
    result.failure = "compiler exited with " & $exitCode
  elif result.sidecar.len == 0:
    result.failure = "compiler produced no result for this file"

proc semanticErrors*(content: string): seq[ParseDiagnostic] =
  ## Undeclared identifiers and the other semantic errors, as the sidecar
  ## records them.
  result = @[]
  for line in content.splitLines:
    let fields = line.split('\t')
    if fields.len >= 5 and fields[0] == "error":
      var lineNo, column = 0
      try:
        lineNo = parseInt(fields[2]).int
        column = parseInt(fields[3]).int
      except:
        continue
      result.add ParseDiagnostic(line: lineNo, col: column,
                                 message: unescapeTsv(fields[4]))

proc nodeAt*(doc: Document; line, character: int): int =
  result = -1
  for n in doc.nodes:
    if n.range.startLine == line and character >= n.range.startCharacter and
        character < n.range.endCharacter:
      return n.id

proc scopeContains(doc: Document; ancestor, descendant: int): bool =
  result = false
  var scope = descendant
  while scope >= 0:
    if scope == ancestor: return true
    scope = doc.scopes[scope].parent

proc isMemberAccess*(doc: Document; line, character: int): bool

proc resolve*(doc: Document; nodeId: int): seq[int] =
  ## Resolve a name lexically, preserving overload candidates in its nearest
  ## visible scope and ignoring unrelated parse errors elsewhere.
  result = @[]
  if nodeId < 0 or nodeId >= doc.nodes.len: return
  let target = doc.nodes[nodeId]
  if doc.isMemberAccess(target.range.startLine, target.range.startCharacter): return
  var nearestDepth = -1
  for candidate in doc.nodes:
    if candidate.declarationKind.len == 0 or candidate.text != target.text: continue
    if not doc.scopeContains(candidate.scope, target.scope): continue
    if candidate.scope != 0 and candidate.startOffset > target.startOffset: continue
    var depth = 0
    var scope = candidate.scope
    while scope > 0:
      inc depth
      scope = doc.scopes[scope].parent
    if depth > nearestDepth:
      result.setLen(0)
      nearestDepth = depth
    if depth == nearestDepth: result.add candidate.id

proc docBlockFirstLine(text: string; lastLine: int): int =
  ## The line a recorded `##` block STARTS on, given the line it ends on.
  ##
  ## The parser keys the table by a block's last line and keeps the merged token
  ## text, whose newlines are exactly the block's interior lines -- so the first
  ## line is the key minus those newlines. Deriving it here rather than keeping a
  ## second table means the two can never disagree.
  var first = lastLine
  for ch in text:
    if ch == '\n': dec first
  first

proc docCommentStartingAt(text: string; startLine: int): string =
  ## The `##` block beginning on 1-based `startLine`, or `""`.
  ##
  ## Read with the project's own lexer, which is what makes the two paths agree.
  ## The open document's text is that lexer's merged token, so a `##[` run, a
  ## blank `##` between paragraphs and the author's indentation come out here
  ## exactly as they do there. The previous line scan could only recognise a
  ## line beginning with `##`, so a block comment contributed just its opening
  ## line and the rest was lost -- and matching that by hand is how the two paths
  ## drift in the first place.
  ##
  ## `openLexer` interns nothing into the symbol pool, so this is safe to call per
  ## query. It is one pass over text the caller has already read from disk.
  var lex = openLexer(text)
  var tok = Token(kind: tkInvalid, s: "", indent: -1, spacing: {},
                 line: 0, col: 0, base: 10, suffixPos: -1)
  next lex, tok
  while tok.kind != tkEof:
    if tok.kind == tkComment and int(tok.line) == startLine:
      return tok.s
    next lex, tok
  ""

proc docCommentAt*(doc: Document; source: string; lineNo, col: int;
                   name: string): string =
  ## The `##` block documenting a declaration.
  ##
  ## For the open document the text is what the parser recorded, which is exact:
  ## it is the block the lexer actually merged, so a `##[` run, a blank `##` line
  ## between paragraphs and leading indentation all come out right without this
  ## function having to know about any of them.
  ##
  ## A Nim doc comment is written *after* the thing it documents: either inline
  ## at the end of the declaration, or as the first statement of its body. A `##`
  ## run above a declaration documents nothing, so the block is looked for
  ## directly below the declaration and never above it. Assuming otherwise is
  ## what made hover report every documented proc in this tree -- where the
  ## convention is overwhelmingly the in-body one -- as undocumented.
  ##
  ## `lineNo` arrives 1-based from some call sites and 0-based from others, so
  ## the line below it is looked for under both readings.
  ##
  ## For any *other* file the tree has nothing -- it only holds the open
  ## document -- so the text is scanned lexically there, exactly as before. That
  ## is the remaining weak spot: it reads the file from disk, so it shows a stale
  ## copy for another open-but-unsaved buffer, and it cannot see a `##[` block.
  let path = if source.isAbsolute: source else: doc.workspaceRoot / source
  if path == doc.path:
    # The table is keyed by a block's LAST line, so the block that documents
    # this declaration is the one *starting* below it. Its first line is its key
    # minus its interior newlines, which the merged text already carries.
    for line in [lineNo, lineNo + 1]:
      for key, text in doc.docComments:
        if text.len > 0 and docBlockFirstLine(text, key) == line:
          return text
  var text = ""
  if path == doc.path: text = doc.text
  else:
    try: text = readFile(path)
    except: discard
  if text.len == 0: return ""
  # Another file's text, so the block is found by scanning down from the
  # declaration, the same direction the table lookup above uses. A signature
  # that wraps over several lines is skipped by bracket depth, so the block is
  # still found under the first statement of the body.
  let lines = text.splitLines()
  var index = max(0, min(lineNo - 1, lines.len - 1))
  var depth = 0
  while index < lines.len:
    for ch in lines[index]:
      if ch in {'(', '[', '{'}: inc depth
      elif ch in {')', ']', '}'}: dec depth
    inc index
    if depth > 0: continue
    break
  docCommentStartingAt(text, index + 1)

proc positionOffset(doc: Document; line, character: int): int =
  result = 0
  var currentLine = 0
  while result < doc.text.len and currentLine < line:
    if doc.text[result] == '\n': inc currentLine
    inc result
  var width = 0
  while result < doc.text.len and doc.text[result] != '\n' and
      width < max(0, character):
    width += utf16Width(doc.text[result])
    inc result

proc utf16Column(text: string; line, byteColumn: int): int =
  result = 0
  var currentLine = 1
  var offset = 0
  while offset < text.len and currentLine < line:
    if text[offset] == '\n': inc currentLine
    inc offset
  let lineEnd = min(text.len, offset + max(0, byteColumn))
  while offset < lineEnd:
    result += utf16Width(text[offset])
    inc offset

proc sourceRange(doc: Document; source: string; line, col: int;
                 name: string): SourceRange {.raises.} =
  let path = if source.isAbsolute: source else: doc.workspaceRoot / source
  var text = ""
  if path == doc.path: text = doc.text
  else:
    try: text = readFile(path)
    except: discard
  var byteColumn = col
  if text.len > 0 and name.len > 0:
    var start = 0
    var currentLine = 1
    while start < text.len and currentLine < line:
      if text[start] == '\n': inc currentLine
      inc start
    var stop = start
    while stop < text.len and text[stop] != '\n': inc stop
    var i = min(stop, start + max(0, col))
    while i + name.len <= stop:
      var matches = text.substr(i, i + name.len - 1) == name
      if name[0] in {'a'..'z', 'A'..'Z', '_'} or ord(name[0]) >= 0x80:
        matches = matches and
          (i == start or not isIdentContinue(text[i - 1])) and
          (i + name.len == stop or not isIdentContinue(text[i + name.len]))
      if matches:
        byteColumn = i - start
        break
      inc i
  var width = name.len
  if text.len > 0:
    var nameWidth = 0
    for c in name: nameWidth += utf16Width(c)
    width = nameWidth
  let lineNo = max(0, line - 1)
  let column = if text.len > 0: utf16Column(text, line, byteColumn) else: col
  SourceRange(startLine: lineNo, startCharacter: column,
              endLine: lineNo, endCharacter: column + width)

proc toUriSeparators(path: string): string =
  ## A URI path uses `/` everywhere. NIF filenames come from the compiler and
  ## may carry `\` on Windows, and `os.isAbsolute` answers for the HOST's rules,
  ## so a foreign absolute path has to be recognized here rather than grafted
  ## onto the workspace root. A leading UNC `\\` becomes `//`.
  result = path.replace('\\', '/')
  if result.len >= 2 and result[1] == ':':
    # A drive-qualified path is absolute whatever the host thinks.
    return result
  if result.len >= 2 and result[0] == '/' and result[1] == '/':
    return result
  if result.len > 0 and result[0] == '/': return result
  ""

proc uriForPath*(doc: Document; source: string): string =
  ## Exported for the URI round-trip tests.
  if source == doc.path: return doc.uri
  var path = toUriSeparators(source)
  if path.len == 0:
    path = toUriSeparators(doc.workspaceRoot / source)
  result = "file://"
  if path.len == 0 or path[0] != '/':
    # Keep the `file://` scheme from swallowing the first segment as a host.
    result.add '/'
  const Hex = "0123456789ABCDEF"
  for c in path:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~', '/', ':'}:
      result.add c
    else:
      result.add '%'
      result.add Hex[(ord(c) shr 4) and 0xF]
      result.add Hex[ord(c) and 0xF]

proc resolveNameAt(doc: Document; name: string; line, character: int): seq[int]

proc symbolFromFields(doc: Document; fields: seq[string]): SemanticSymbol {.raises.} =
  ## `candidate` and `import` rows share a shape: name, kind, file, line, col,
  ## is-local.
  result = SemanticSymbol(name: fields[1], kind: fields[2], uri: "", doc: "")
  let source = if fields[3].len > 0: realFile(fields[3]) else: ""
  if source.len == 0: return
  result.uri = doc.uriForPath(source)
  var lineNo, column = 0
  try:
    lineNo = parseInt(fields[4]).int
    column = parseInt(fields[5]).int
  except:
    return
  result.doc = doc.docCommentAt(source, lineNo, column, fields[1])
  result.range = doc.sourceRange(source, lineNo, column, fields[1])

proc parseIdeSnapshot*(doc: Document; content: string; queryLine,
                       queryCharacter: int): SemanticSnapshot {.raises.} =
  ## Exported so a test can compare against the reader the editor really uses.
  ## A second implementation of this format written in the test would only prove
  ## it agrees with itself: had `escapeTsv` and `unescapeTsv` drifted apart,
  ## matching them against a copy would pass while the sidecar had become
  ## unreadable to the editor. Comparing the writer against this reader can only
  ## fail when one of them is wrong.
  result = SemanticSnapshot(queried: true, matched: false,
                            visible: @[], candidates: @[])
  let rows = content.splitLines()
  var i = 0
  while i < rows.len:
    let fields = rows[i].split('\t')
    inc i
    if fields.len == 2 and fields[0] == "matched":
      result.matched = fields[1] == "true"
    elif fields.len >= 5 and fields[0] == "position":
      # Document mode. The header carries the count of the `candidate` rows
      # that FOLLOW it, so they are consumed here rather than matched by tag:
      # two occurrences of one name on one line each get their own run.
      var lineNo, column, count = 0
      try:
        lineNo = parseInt(fields[1]).int
        column = parseInt(fields[2]).int
        count = parseInt(fields[4]).int
      except:
        continue
      var symbols: seq[SemanticSymbol] = @[]
      for id in 0 ..< count:
        if i >= rows.len: break
        let candidate = rows[i].split('\t')
        inc i
        if candidate.len >= 7 and candidate[0] == "candidate":
          symbols.add doc.symbolFromFields(candidate)
      result.positions.add IdePosition(line: lineNo, column: column,
                                       name: unescapeTsv(fields[3]),
                                       symbols: symbols)
    elif fields.len >= 7 and fields[0] == "import":
      result.imports.add doc.symbolFromFields(fields)
    elif fields.len >= 4 and fields[0] == "signature":
      # Keyed by name and params, not by position: there is no identifier at the
      # cursor mid-call -- the callee's name is behind it. So this cannot use the
      # row's own line/col the way `visible` and `dotmember` do.
      result.signatures.add SemanticSignature(name: fields[1], kind: fields[2],
                                             params: unescapeTsv(fields[3]))
    elif fields.len >= 6 and fields[0] == "dotmember":
      # A dot's members. Read from the row's own position rather than re-resolved
      # through the syntax index, for the reason the `visible` branch above spells
      # out: an enum field has no syntax node, so re-resolving drops every row.
      var lineNo, column = 0
      try:
        lineNo = parseInt(fields[4])
        column = parseInt(fields[5])
      except:
        continue
      let source = if fields[3].len > 0: realFile(fields[3]) else: ""
      result.dotMembers.add SemanticSymbol(name: fields[1], kind: fields[2],
        uri: doc.uriForPath(source),
        range: doc.sourceRange(source, lineNo, column, fields[1]),
        doc: doc.docCommentAt(source, lineNo, column, fields[1]))
    elif fields.len >= 7 and fields[0] == "visible":
      var lineNo, column = 0
      try:
        lineNo = parseInt(fields[4])
        column = parseInt(fields[5])
      except:
        continue
      let source = if fields[3].len > 0: realFile(fields[3]) else: ""
      let isLocal = fields[6] == "true"
      if isLocal or source == doc.path:
        let resolved = doc.resolveNameAt(fields[1], queryLine, queryCharacter)
        if resolved.len == 0:
          # The syntax index has no node for this name, which is the normal case
          # for a type's members: an enum field is not a statement the parser
          # records a declaration for. The row already carries the declaration's
          # own file, line and column, so use those rather than dropping it --
          # dropping is what made post-dot completion answer nothing at all.
          let symbol = SemanticSymbol(name: fields[1], kind: fields[2],
            uri: doc.uriForPath(source),
            range: doc.sourceRange(source, lineNo, column, fields[1]),
            doc: doc.docCommentAt(source, lineNo, column, fields[1]))
          if fields[0] == "visible": result.visible.add symbol
          else: result.candidates.add symbol
          continue
        for id in resolved:
          let n = doc.nodes[id]
          let symbol = SemanticSymbol(name: fields[1], kind: fields[2],
            uri: doc.uri, range: n.range,
            doc: doc.docCommentAt(doc.path, n.range.startLine + 1,
                                  n.range.startCharacter, n.text))
          if fields[0] == "visible": result.visible.add symbol
          else: result.candidates.add symbol
      elif source.len > 0:
        let symbol = SemanticSymbol(name: fields[1], kind: fields[2],
          uri: doc.uriForPath(source),
          doc: doc.docCommentAt(source, lineNo, column, fields[1]),
          range: doc.sourceRange(source, lineNo, column, fields[1]))
        if fields[0] == "visible": result.visible.add symbol
        else: result.candidates.add symbol
      else:
        let symbol = SemanticSymbol(name: fields[1], kind: fields[2], uri: "",
                                    range: SourceRange())
        if fields[0] == "visible": result.visible.add symbol
        else: result.candidates.add symbol

proc symbolAtInfo(doc: Document; name, kind: string; lineNo, column: int;
                  source: string): SemanticSymbol {.raises.} =
  ## A symbol placed from the position its own record carries.
  ##
  ## This is what `symbolFromFields` does for a `candidate`, `import` or
  ## `dotmember` row: take the declaration's file, line and column from the row
  ## rather than looking anything up. That is the whole reason document-mode
  ## resolution survives at all -- a `position` row's candidates are the
  ## resolution sem already computed, and re-deriving them from the syntax index
  ## can land on a different occurrence of the same name. For a shadowed name that
  ## is the difference between the inner declaration and the outer one, which is
  ## not a subtle difference: it is the wrong answer.
  if source.len == 0:
    return SemanticSymbol(name: name, kind: kind, uri: "", range: SourceRange())
  SemanticSymbol(name: name, kind: kind, uri: doc.uriForPath(source),
                 range: doc.sourceRange(source, lineNo, column, name),
                 doc: doc.docCommentAt(source, lineNo, column, name))

proc symbolForSym(doc: Document; sym: IdeSymbol; moduleSuffix: string;
                  queryLine, queryCharacter: int;
                  resolveAtCursor: bool): SemanticSymbol {.raises.} =
  ## One symbol as the editor sees it, from a resolved `SymId`.
  ##
  ## Every value here comes from where `symbolFromFields` takes it -- `symBasename`,
  ## `$kind`, the declaration's file/line/column -- so the two readers cannot
  ## drift on what a symbol *is*.
  ##
  ## `isLocal` is `pool.symModule(id) == moduleSuffix`, the same comparison
  ## `writeIdeQuery` makes per row. It is not recoverable from the `SymId` once the
  ## run is over, which is why `IdeQueryResult` carries `moduleSuffix`.
  ##
  ## `resolveAtCursor` mirrors the reader's `visible` branch and nothing else. A
  ## `visible` row says where a symbol is in scope; the answer is where the
  ## *occurrence* under the cursor is, and the syntax index is the only thing that
  ## knows. The fallback when that index has no node for the name is load-bearing
  ## rather than incidental: an enum field is not a statement the parser records a
  ## declaration for, so the row's own position is the only answer left, and
  ## dropping it is what made post-dot completion return nothing at all.
  let name = pool.symBasename(sym.id)
  let source = if sym.info.file.isValid: realFile(pool.filenames[sym.info.file])
               else: ""
  let lineNo = sym.info.line.uint32.int
  let column = sym.info.col.uint32.int
  if not resolveAtCursor or source.len == 0:
    return doc.symbolAtInfo(name, $sym.kind, lineNo, column, source)
  if pool.symModule(sym.id) != moduleSuffix and source != doc.path:
    # An import this file can see but not own: the syntax index only ever holds
    # this document's nodes, so the row is the only answer.
    return doc.symbolAtInfo(name, $sym.kind, lineNo, column, source)
  let resolved = doc.resolveNameAt(name, queryLine, queryCharacter)
  if resolved.len == 0:
    return doc.symbolAtInfo(name, $sym.kind, lineNo, column, source)
  result = doc.symbolAtInfo(name, $sym.kind, lineNo, column, source)
  for id in resolved:
    let n = doc.nodes[id]
    result = SemanticSymbol(name: name, kind: $sym.kind, uri: doc.uri,
      range: n.range,
      doc: doc.docCommentAt(doc.path, n.range.startLine + 1,
                            n.range.startCharacter, n.text))

proc snapshotFromQuery*(doc: Document; res: IdeQueryResult; queryLine,
                        queryCharacter: int): SemanticSnapshot {.raises.} =
  ## The sidecar's reader, fed the struct instead of the text.
  ##
  ## This is `parseIdeSnapshot` over a different transport, and it is a second
  ## implementation rather than a shared one: the sidecar is text on a wire and
  ## the struct is not, so there is no single code path to factor out without
  ## inventing a representation both could be lowered from -- which would be the
  ## 6.4 MB TSV this exists to avoid.
  ##
  ## So the two are held to agreeing by `tests/lsp/boundary.nim`, which runs both
  ## over one sem run and compares them field by field, in both modes. That is the
  ## only thing making a second reader safe, and it is why the test exists.
  result = SemanticSnapshot(queried: res.queried, matched: res.matched,
                            documentMode: res.documentMode,
                            visible: @[], candidates: @[], imports: @[],
                            dotMembers: @[], signatures: @[], positions: @[])
  if res.documentMode:
    for pos in res.positions:
      var symbols: seq[SemanticSymbol] = @[]
      for sym in pos.candidates:
        symbols.add doc.symbolForSym(sym, res.moduleSuffix, queryLine,
                                      queryCharacter, resolveAtCursor = false)
      result.positions.add IdePosition(line: pos.info.line.uint32.int,
                                       column: pos.info.col.uint32.int,
                                       name: pool.strings[pos.name],
                                       symbols: symbols)
  for sym in res.imports:
    result.imports.add doc.symbolForSym(sym, res.moduleSuffix, queryLine,
                                        queryCharacter, resolveAtCursor = false)
  for sym in res.dotMembers:
    result.dotMembers.add doc.symbolForSym(sym, res.moduleSuffix, queryLine,
                                            queryCharacter,
                                            resolveAtCursor = false)
  for sig in res.signatures:
    result.signatures.add SemanticSignature(name: pool.symBasename(sig.sym),
                                           kind: $sig.kind, params: sig.params)
  for sym in res.visible:
    result.visible.add doc.symbolForSym(sym, res.moduleSuffix, queryLine,
                                         queryCharacter, resolveAtCursor = true)
  for sym in res.candidates:
    result.candidates.add doc.symbolForSym(sym, res.moduleSuffix, queryLine,
                                            queryCharacter,
                                            resolveAtCursor = true)

proc semInProcess*: bool =
  ## Whether to answer queries by running sem inside this process.
  ##
  ## Off by default and read from the environment rather than a command-line flag
  ## because the language server is started by an editor, not by a user who can
  ## be asked to spell a flag correctly. `NIMONY_LSP_INPROCESS=1` turns it on.
  ##
  ## Off by default because in-process sem is still unproven on a real file over a
  ## long session, and the subprocess path is the one that has been measured. This
  ## is the switch that lets both run against the same corpus before either is
  ## trusted.
  let v = getEnv("NIMONY_LSP_INPROCESS")
  v.len > 0 and v != "0"

proc dependencyClosureReady(db: Database; doc: Document): bool =
  ## Whether in-process sem can read this document's imports out of the cache.
  ##
  ## It cannot do its own dependency resolution: `deps.nim` is what walks the
  ## import graph and sems each dependency, and that runs in `nifmake`, ahead of
  ## sem proper. A subprocess does not care, because `nifmake` IS the thing that
  ## arranges the closure. In-process has to be *told* the closure is there.
  ##
  ## So the test is deliberately coarse: has this document already been checked
  ## once by the subprocess path? That run built the closure as a side effect, and
  ## from then on in-process can read it. It does not try to verify the closure
  ## itself. An earlier version walked the `.p.deps.nif` and checked each
  ## `include`, which is wrong twice over: the file lists direct imports only,
  ## not the transitive closure, so it reported a cold cache as ready; and it
  ## picked up the `.vendor` and `.dialect` header strings as if they were
  ## imports, so it reported a *warm* cache as cold. In-process was off in
  ## practice while the flag said it was on -- which read as "wired up, no
  ## speedup" until the timing was actually measured.
  ##
  ## It has to be a pre-flight and not a `try`. `vfs.openMmapImpl` answers a
  ## missing interface with `quit`, which ends the process outright and which
  ## nothing in the editor can catch: the first cold query killed the server
  ## rather than falling back.
  result = false
  if not os.fileExists(db.cacheDir / (doc.moduleName & ".s.nif")): return false
  # `std/system` is imported implicitly rather than listed, and it is the one
  # import sem always needs.
  if not os.fileExists(db.cacheDir / (SystemModuleSuffix & ".s.nif")): return false
  result = true

proc runSemInProcess*(db: Database; doc: Document;
                      line, character: int): IdeQueryResult {.raises.} =
  ## One sem run, in this process, over `doc`'s already-parsed tree.
  ##
  ## The parsed `.p.nif` is written by `updateDocument` on every change, which is
  ## cheap because it is only the parse output. sem reads it and does the work
  ## that used to require `fork`/`exec` of `bin/nimony` plus a second parse of
  ## the sidecar text.
  ##
  ## Three constraints, all found by running this rather than by reading it:
  ##
  ## - `stdlibFile` resolves against the *executable's* parent directory. This
  ##   binary is `bin/nimony-lsp`, so that happens to be right, but it is a
  ##   coincidence of where the file sits and not something to rely on.
  ## - `setupPaths` must be called or every module suffix is computed against no
  ##   search path and names a `.s.nif` nobody wrote.
  ## - The dependency closure must already be semmed into the cache. `deps.nim`
  ##   does that in `nifmake`, ahead of sem; in-process skips it. On a cache that
  ##   has never been built this fails on the first import, which is why the
  ##   subprocess path stays available as a fallback rather than this being the
  ##   only way to answer a query.
  setProjectRoot(db.root)
  var config = initNifConfig(db.root)
  config.nifcachePath = db.cacheDir
  config.setupPaths()
  # Built as a `seq` rather than an array literal: mixing a `seq[string]` into
  # one infers a nested element type, and the error it reports points at the
  # literal rather than at the mix.
  var paths: seq[string] = @[db.root, db.root / "lib", db.root / "src" / "lib"]
  for p in db.modulePaths: paths.add p
  # The open document's own directory, which `runCompiler` also passes as
  # `--path:`. A `./`-less sibling import (`import sibling_dep_helper`) resolves
  # against the *importing* file's directory, so without this it resolves to
  # nothing: sem creates the node with no parse rule and the build dies on a
  # missing interface. Same reason, same fix -- kept here because the two paths
  # build their search paths separately and would otherwise drift.
  let docDir = parentDir(doc.path)
  if docDir.len > 0: paths.add docDir
  config.paths = paths
  # Line 0 is document mode: every identifier occurrence in one pass, which is
  # what `runDiagnostics` wants. A real line asks about one position, which is
  # what a cursor query wants.
  if line < 0:
    config.toTrack = TrackPosition(mode: TrackVisible, line: 0, col: 0,
                                   filename: doc.path)
  else:
    let offset = doc.positionOffset(line, character)
    var lineStart = offset
    while lineStart > 0 and doc.text[lineStart - 1] != '\n': dec lineStart
    config.toTrack = TrackPosition(mode: TrackVisible, line: (line + 1).int32,
                                   col: (offset - lineStart + 1).int32,
                                   filename: doc.path)
  # The sidecar is still written -- `writeIdeQuery` runs inside `semcheckCore` --
  # and left in place deliberately for now. It is what `semanticErrors` reads,
  # and the boundary test compares the struct against it. Removing it is the next
  # step, and it needs errors to travel in the struct first.
  result = semcheckInProcess(@[doc.parsedFile],
                             @[db.cacheDir / (doc.moduleName & ".s.nif")],
                             config, {}, "", "", false)

proc ideQueryAt*(db: Database; doc: Document; line, character: int;
                 memberRequest = false;
                 needCursorQuery = false): SemanticSnapshot {.raises.} =
  ## The answer for a cursor position. When the document was checked in document
  ## mode this is a lookup in the recorded positions and spawns nothing; the
  ## per-position compile is the fallback for a document sem has not run on.
  ##
  ## Two requests must skip the snapshot even when one exists, and the discriminator
  ## in both is the request kind rather than the shape of the position.
  ##
  ## `needCursorQuery` is signature help: it asks which overloads the call could
  ## still resolve to, and sem only ever records that for a cursor query. Sharing
  ## `memberRequest` with it would be wrong twice over -- it would also suppress
  ## the scope-chain walk, which a signature does not need -- so it is a separate
  ## flag rather than an overload of one. The answer is the receiver's members, which depend on
  ## the receiver's *type*; the snapshot answers "what is in scope here", which is
  ## a different question, and the recorded import table is no substitute because
  ## it lists every name in sight rather than this type's.
  ##
  ## Deciding it by position instead does not work. Testing whether the character
  ## before the cursor is a dot is true for `k.` and false for `k.co`, so it
  ## selects the rare case and misses the partial name that completion exists for;
  ## testing whether an occurrence is recorded there is no better, because a
  ## half-typed name resolves to nothing and so looks absent. `memberRequest` is
  ## passed in by the caller, which knows which of the three handlers it is.
  ##
  ## Hover and go-to-definition keep the snapshot even on a member name, because
  ## there the resolution *is* the answer -- and for an overloaded name it is the
  ## one that matters.
  if doc.snapshot.positions.len > 0 and not memberRequest and not needCursorQuery:
    let position = doc.snapshot.positionAt(line, character)
    result = SemanticSnapshot(queried: true, matched: position.symbols.len > 0,
                              documentMode: true, visible: @[],
                              candidates: position.symbols,
                              imports: doc.snapshot.imports,
                              positions: @[])
    return
  # A checked document can also have *no* recorded positions -- an empty buffer,
  # or one holding only comments -- and then there is nothing to look up. That is
  # no reason to compile: document mode records every occurrence in the file, so
  # zero positions means there is no identifier for the per-position mode to find
  # either. Compiling anyway cost a `nimony check` per cursor position, and the
  # cache only covers a repeat of the *same* line and column. So a new file --
  # which is what an editor creates one of per session -- paid a full compile on
  # every keystroke, and a large file whose compile failed outright, leaving no
  # sidecar to record anything, paid one per hover across its whole import graph.
  if doc.snapshot.queried and not memberRequest and not needCursorQuery:
    return SemanticSnapshot(queried: true, matched: false,
                            visible: @[], candidates: @[])
  if doc.queryCached and doc.queryLine == line and doc.queryCharacter == character:
    return doc.queryResult
  result = SemanticSnapshot(queried: true, matched: false,
                            visible: @[], candidates: @[])
  doc.queryLine = line
  doc.queryCharacter = character
  if semInProcess() and db.dependencyClosureReady(doc):
    try:
      let res = db.runSemInProcess(doc, line, character)
      if not res.documentMode:
        result = snapshotFromQuery(doc, res, line, character)
        doc.queryCached = true
        doc.queryResult = result
        return
      # Document mode answers from the recorded occurrences instead, which is the
      # path below and costs no compile at all.
    except:
      # The exception's message is not reachable from a bare `except` in this
      # stdlib, so the fallback reason is logged without it. stderr, because
      # stdout is the JSON-RPC transport.
      stderr.writeLine "[nimony-lsp] in-process sem failed, falling back to the subprocess"
  let content = db.runCompiler(doc)
  if content.sidecar.len > 0: result = parseIdeSnapshot(doc, content.sidecar, line, character)
  doc.queryCached = true
  doc.queryLine = line
  doc.queryCharacter = character
  doc.queryResult = result

proc isMemberAccess*(doc: Document; line, character: int): bool =
  var offset = doc.positionOffset(line, character)
  while offset > 0 and doc.text[offset - 1] in {' ', '\t'}: dec offset
  result = offset > 0 and doc.text[offset - 1] == '.'

proc memberCompletionAt*(doc: Document; line, character: int): bool =
  ## Is the cursor completing a member name -- i.e. does the identifier run it
  ## sits in follow a `.`?
  ##
  ## Not the same question as `isMemberAccess`, which only sees a dot when the
  ## cursor is *immediately* after it. That makes it true for `k.` and false for
  ## `k.c`, `k.co`, `k.col` -- so it identifies the empty case, which is the rare
  ## one, and misses the partial name, which is what completion is actually for.
  ## Scanning back over the identifier run first makes all four the same question.
  var offset = doc.positionOffset(line, character)
  while offset > 0 and isIdentContinue(doc.text[offset - 1]): dec offset
  result = offset > 0 and doc.text[offset - 1] == '.'

proc scopeAtLine(doc: Document; line: int): int =
  var indent = 0
  var currentLine = 0
  var i = 0
  while i < doc.text.len and currentLine < line:
    if doc.text[i] == '\n': inc currentLine
    inc i
  while i < doc.text.len and doc.text[i] in {' ', '\t'}:
    indent += (if doc.text[i] == '\t': 2 else: 1)
    inc i
  result = 0
  var bestIndent = -1
  for scope in doc.scopes:
    if scope.indent <= indent and scope.indent > bestIndent:
      bestIndent = scope.indent
      result = scope.id

proc resolveNameAt(doc: Document; name: string; line, character: int): seq[int] =
  result = @[]
  if doc.isMemberAccess(line, character): return
  let nodeId = doc.nodeAt(line, character)
  let scope = if nodeId >= 0: doc.nodes[nodeId].scope else: doc.scopeAtLine(line)
  let offset = if nodeId >= 0: doc.nodes[nodeId].startOffset
               else: doc.positionOffset(line, character)
  var nearestDepth = -1
  for candidate in doc.nodes:
    if candidate.declarationKind.len == 0 or candidate.text != name: continue
    if not doc.scopeContains(candidate.scope, scope): continue
    if candidate.scope != 0 and candidate.startOffset > offset: continue
    var depth = 0
    var parent = candidate.scope
    while parent > 0:
      inc depth
      parent = doc.scopes[parent].parent
    if depth > nearestDepth:
      result.setLen(0)
      nearestDepth = depth
    if depth == nearestDepth: result.add candidate.id

proc visible*(doc: Document; line, character: int): seq[int] =
  result = @[]
  let nodeId = doc.nodeAt(line, character)
  let scope = if nodeId >= 0: doc.nodes[nodeId].scope else: doc.scopeAtLine(line)
  let offset = if nodeId >= 0: doc.nodes[nodeId].startOffset
               else: doc.positionOffset(line, character)
  var bestDepth = initTable[string, int]()
  for n in doc.nodes:
    if n.declarationKind.len == 0: continue
    if n.scope != 0 and n.startOffset > offset: continue
    if not doc.scopeContains(n.scope, scope): continue
    var depth = 0
    var parent = n.scope
    while parent > 0:
      inc depth
      parent = doc.scopes[parent].parent
    if depth > bestDepth.getOrDefault(n.text, -1):
      bestDepth[n.text] = depth
  for n in doc.nodes:
    if n.declarationKind.len == 0 or n.scope != 0 and n.startOffset > offset: continue
    if not doc.scopeContains(n.scope, scope): continue
    var depth = 0
    var parent = n.scope
    while parent > 0:
      inc depth
      parent = doc.scopes[parent].parent
    if depth == bestDepth.getOrDefault(n.text, -1): result.add n.id
