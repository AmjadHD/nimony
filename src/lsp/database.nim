## Per-document syntax database for the LSP. Syntax records are token/node
## granular; semantic name visibility is rebuilt for the containing document.

{.feature: "lenientnils".}

import std / [tables, strutils, os, hashes, dirs, paths, syncio, osproc]
import ../nifler2 / [nimgrammar, parserrt]
import ../nifler2 / niflerout
import ../lib / comesfrom
import ../gear2 / modnames

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
    positions*: seq[IdePosition]

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
  let content = db.runCompiler(doc)
  doc.snapshot = parseIdeSnapshot(doc, content, -1, -1)
  correctPositionColumns(doc)
  doc.semanticDiagnostics = semanticErrors(content)

proc updateDocument*(db: var Database; uri, path: string; version: int;
                     text: string): Document {.raises.} =
  var doc = Document(uri: uri, path: path, workspaceRoot: db.root,
                     version: version, text: text)
  var p = openParser(text, path, pool, globalTags)
  p.recovering = true
  parseModule p
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
  result = IdePosition(line: -1, column: -1)
  var best = high(int)
  for position in snapshot.positions:
    if position.line != line + 1: continue
    let width = position.name.len
    if character < position.column or character >= position.column + width: continue
    let distance = character - position.column
    if distance < best:
      best = distance
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

proc runCompiler*(db: Database; doc: Document): string {.raises.} =
  ## Run sem for `doc` and return its sidecar. Both the semantic query and the
  ## diagnostics come out of this one invocation, so a query never costs a
  ## second compile.
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
  let _ = execCmdEx(command, workingDir = db.root)
  if os.fileExists(ideFile): readFile(ideFile) else: ""

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

proc docCommentAt*(doc: Document; source: string; lineNo, col: int;
                   name: string): string =
  ## The `##` block directly above a declaration. NIF carries no comments --
  ## the parser drops them -- so the text is read back from the source. The
  ## scan stops at the first line that is not a doc comment, which is what makes
  ## this the comment for THIS declaration and not one further up.
  let path = if source.isAbsolute: source else: doc.workspaceRoot / source
  var text = ""
  if path == doc.path: text = doc.text
  else:
    try: text = readFile(path)
    except: discard
  if text.len == 0: return ""
  var lines: seq[string] = @[]
  var start = 0
  var current = 1
  while current < lineNo and start < text.len:
    if text[start] == '\n': inc current
    inc start
  var stop = start
  while stop < text.len and text[stop] != '\n': inc stop
  var scan = start
  var collected: seq[string] = @[]
  while scan > 0:
    dec scan
    if text[scan] == '\n': continue
    var lineEnd = scan + 1
    while lineEnd < text.len and text[lineEnd] != '\n': inc lineEnd
    var lineStart = lineEnd
    while lineStart > 0 and text[lineStart - 1] != '\n': dec lineStart
    var firstNonSpace = lineStart
    while firstNonSpace < lineEnd and text[firstNonSpace] in {' ', '\t'}:
      inc firstNonSpace
    if firstNonSpace + 1 < lineEnd and text[firstNonSpace] == '#' and
        text[firstNonSpace + 1] == '#':
      var body = text[firstNonSpace + 2 ..< lineEnd]
      if body.len > 0 and body[0] == ' ': body = body[1 .. ^1]
      collected.add body
      scan = lineStart
    else:
      break
  if collected.len == 0: return ""
  for i in countdown(collected.high, 0):
    lines.add collected[i]
  lines.join("\n")

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

proc parseIdeSnapshot(doc: Document; content: string; queryLine,
                      queryCharacter: int): SemanticSnapshot {.raises.} =
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
        for id in doc.resolveNameAt(fields[1], queryLine, queryCharacter):
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

proc ideQueryAt*(db: Database; doc: Document; line, character: int): SemanticSnapshot {.raises.} =
  ## The answer for a cursor position. When the document was checked in document
  ## mode this is a lookup in the recorded positions and spawns nothing; the
  ## per-position compile is the fallback for a snapshot that has none.
  if doc.snapshot.positions.len > 0:
    let position = doc.snapshot.positionAt(line, character)
    result = SemanticSnapshot(queried: true, matched: position.symbols.len > 0,
                              documentMode: true, visible: @[],
                              candidates: position.symbols,
                              imports: doc.snapshot.imports,
                              positions: @[])
    return
  if doc.queryCached and doc.queryLine == line and doc.queryCharacter == character:
    return doc.queryResult
  result = SemanticSnapshot(queried: true, matched: false,
                            visible: @[], candidates: @[])
  doc.queryLine = line
  doc.queryCharacter = character
  let content = db.runCompiler(doc)
  if content.len > 0: result = parseIdeSnapshot(doc, content, line, character)
  doc.queryCached = true
  doc.queryLine = line
  doc.queryCharacter = character
  doc.queryResult = result

proc isMemberAccess*(doc: Document; line, character: int): bool =
  var offset = doc.positionOffset(line, character)
  while offset > 0 and doc.text[offset - 1] in {' ', '\t'}: dec offset
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
