## Per-document syntax database for the LSP. Syntax records are token/node
## granular; semantic name visibility is rebuilt for the containing document.

{.feature: "lenientnils".}

import std / [tables, strutils, os, hashes, dirs, paths, syncio]
import ../nifler2 / [nimgrammar, parserrt]

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

  Document* = ref object
    uri*, path*: string
    version*: int
    text*: string
    nodes*: seq[SyntaxNode]
    scopes*: seq[ScopeNode]
    diagnostics*: seq[ParseDiagnostic]
    nifTree*: string
    cacheFile*: string

  Database* = object
    root*, cacheDir*: string
    documents*: Table[string, Document]

const DeclKeywords = ["let", "var", "const", "type", "proc", "func",
                      "iterator", "template", "macro", "method", "converter"]

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

proc updateDocument*(db: var Database; uri, path: string; version: int;
                     text: string): Document {.raises.} =
  var doc = Document(uri: uri, path: path, version: version, text: text)
  var p = openParser(text, path, pool, globalTags)
  p.recovering = true
  parseModule p
  doc.diagnostics = p.errors
  let tree = finish(p)
  doc.nifTree = toString(tree)
  p.close()
  doc.indexSyntax()
  let key = $hash(uri)
  doc.cacheFile = db.cacheDir / (key & ".nif")
  try:
    writeFile(doc.cacheFile, doc.nifTree)
  except:
    discard
  db.documents[uri] = doc
  result = doc

proc closeDocument*(db: var Database; uri: string) {.raises.} =
  if db.documents.hasKey(uri):
    let cacheFile = db.documents.getOrDefault(uri).cacheFile
    try:
      if fileExists(cacheFile): removeFile(path(cacheFile))
    except:
      discard
    db.documents.del(uri)

proc document*(db: Database; uri: string): Document {.raises.} =
  db.documents.getOrDefault(uri)

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
