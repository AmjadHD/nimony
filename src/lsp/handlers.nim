## LSP request handlers. Resolution is lexical Phase 2v1: unresolved or
## type-dependent expressions return no result instead of guessing.

{.feature: "lenientnils".}

import std / [json, strutils, uri, sets]
import ../nifler2 / parserrt
import database

type HandlerResult* = object
  response*, notification*: string
  stop*: bool

proc quoteJson(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ord(c) < 0x20:
        const Hex = "0123456789abcdef"
        result.add "\\u00"
        result.add Hex[(ord(c) shr 4) and 0xF]
        result.add Hex[ord(c) and 0xF]
      else:
        result.add c
  result.add '"'

proc isEmpty(node: JsonNode): bool {.inline.} =
  ## A missing `params` is a default-constructed JsonNode, and `kind` on it
  ## dereferences a nil cursor. Every accessor here is reachable with whatever
  ## the peer sent, so the check comes before any read.
  cursorIsNil(node.c)

proc field(node: JsonNode; name: string): JsonNode =
  if node.isEmpty or kind(node) != JObject: return JsonNode()
  for key, value in pairs(node):
    if key == name: return value
  result = JsonNode()

proc hasField(node: JsonNode; name: string): bool =
  if node.isEmpty or kind(node) != JObject: return false
  for key, value in pairs(node):
    if key == name: return true
  result = false

proc strField(node: JsonNode; name: string): string =
  ## A missing field and a field of the wrong type are both simply no value:
  ## `getStr` on a wrong-kind node is a crash, not an error.
  let value = node.field(name)
  if value.isEmpty: return ""
  if kind(value) == JString: value.getStr
  elif kind(value) == JInt: $value.getInt
  else: ""

proc intField(node: JsonNode; name: string): int64 =
  let value = node.field(name)
  if value.isEmpty: return 0
  if kind(value) == JInt: value.getInt
  elif kind(value) == JFloat: value.getFloat.int64
  else: 0

proc boolField(node: JsonNode; name: string; fallback: bool): bool =
  ## A missing or non-boolean field takes the caller's default rather than being
  ## treated as false: `includeDeclaration` absent should include.
  let value = node.field(name)
  if value.isEmpty: return fallback
  if kind(value) == JBool: value.getBool
  else: fallback

proc stringField(node: JsonNode; name: string): string =
  node.strField(name)

proc rpcId(node: JsonNode): string =
  case kind(node)
  of JInt: $node.getInt
  of JString: quoteJson(node.getStr)
  else: "null"

proc posJson(line, character: int): string =
  "{\"line\":" & $line & ",\"character\":" & $character & "}"

proc rangeJson(r: SourceRange): string =
  "{\"start\":" & posJson(r.startLine, r.startCharacter) &
    ",\"end\":" & posJson(r.endLine, r.endCharacter) & "}"

proc diagnosticJson(d: ParseDiagnostic; severity: int; source: string): string =
  let line = max(0, d.line - 1)
  let col = max(0, d.col)
  "{\"range\":{\"start\":" & posJson(line, col) &
    ",\"end\":" & posJson(line, col + 1) &
    "},\"severity\":" & $severity & ",\"source\":\"" & source &
    "\",\"message\":" & quoteJson(d.message) & "}"

proc diagnosticsJson(doc: Document): string =
  ## Parser and sem diagnostics together. Both refer to positions in this
  ## document's text, so the editor underlines both in one pass.
  result = "["
  var first = true
  for d in doc.diagnostics:
    if not first: result.add ','
    first = false
    result.add diagnosticJson(d, 1, "nimony")
  for d in doc.semanticDiagnostics:
    if not first: result.add ','
    first = false
    result.add diagnosticJson(d, 1, "nimony")
  result.add ']'

proc uriPath(uriText: string): string {.raises.} =
  ## The inverse of `uriForPath`. `file://` is followed by an empty authority
  ## and then the path, so three slashes mean one leading slash in the path --
  ## except for a drive letter, where `/C:/x` is the conventional spelling and
  ## the extra slash is not part of the filename.
  if not uriText.startsWith("file://"): return uriText
  var rest = uriText[7 .. ^1]
  # A non-empty authority (`file://host/share`) is not a local path; leave it.
  if rest.len > 0 and rest[0] != '/': return decodeUrl(rest)
  rest = decodeUrl(rest)
  # `/C:/x` is how a drive letter is spelled in a URI; the slash is not part of
  # the filename.
  if rest.len >= 3 and rest[0] == '/' and rest[1] in {'a'..'z', 'A'..'Z'} and
      rest[2] == ':':
    return rest[1 .. ^1]
  rest

proc publishDiagnostics(doc: Document): string =
  "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{" &
    "\"uri\":" & quoteJson(doc.uri) & ",\"diagnostics\":" &
    diagnosticsJson(doc) & "}}"

proc docPosition(params: JsonNode): tuple[line, character: int] =
  let pos = field(params, "position")
  (int(pos.intField("line")), int(pos.intField("character")))

proc definitionJson(doc: Document; nodeId: int; query: SemanticSnapshot): string =
  result = "["
  # Prefer the compiler's choice, fall back to lexical resolution when it
  # matched nothing.
  if query.matched:
    var first = true
    for symbol in query.candidates:
        if symbol.uri.len == 0: continue
        if not first: result.add ','
        first = false
        result.add "{\"uri\":" & quoteJson(symbol.uri) &
          ",\"range\":" & rangeJson(symbol.range) & "}"
  else:
    let resolved = doc.resolve(nodeId)
    for i, id in resolved:
      if i > 0: result.add ','
      let n = doc.nodes[id]
      result.add "{\"uri\":" & quoteJson(doc.uri) &
        ",\"range\":" & rangeJson(n.range) & "}"
  result.add ']'

proc hoverJson(doc: Document; nodeId: int; query: SemanticSnapshot): string =
  ## Signature line, then the declaration's doc comment when there is one.
  ## Editors show the markdown as a popup, so the doc text goes in as plain
  ## markdown below the code span.
  # A query that matched nothing (the cursor is on a declaration, or sem did
  # not run) still deserves the lexical answer rather than nothing at all.
  if query.candidates.len > 0:
    let symbol = query.candidates[0]
    var value = "`" & symbol.kind & " " & symbol.name & "`"
    if symbol.doc.len > 0:
      if symbol.doc.contains("\n"):
        value.add "\n\n```nim\n" & symbol.doc & "\n```"
      else:
        value.add "\n\n" & symbol.doc
    return "{\"contents\":{\"kind\":\"markdown\",\"value\":" & quoteJson(value) &
      "},\"range\":" & rangeJson(symbol.range) & "}"
  let resolved = doc.resolve(nodeId)
  if resolved.len == 0: return "null"
  let decl = doc.nodes[resolved[0]]
  let kindName = if decl.declarationKind.len > 0: decl.declarationKind else: "symbol"
  var value = "`" & kindName & " " & decl.text & "`"
  let docs = doc.docCommentAt(doc.path, decl.range.startLine + 1,
                             decl.range.startCharacter, decl.text)
  if docs.len > 0:
    if docs.contains("\n"):
      value.add "\n\n```nim\n" & docs & "\n```"
    else:
      value.add "\n\n" & docs
  # The cursor is not on a syntax node -- a member name, say -- so the range
  # falls back to the declaration's, which is what the editor should underline
  # anyway: it is the thing being described.
  let hoverRange = if nodeId >= 0: doc.nodes[nodeId].range else: decl.range
  "{\"contents\":{\"kind\":\"markdown\",\"value\":" & quoteJson(value) &
    "},\"range\":" & rangeJson(hoverRange) & "}"

proc completionJson(doc: Document; line, character: int; query: SemanticSnapshot): string =
  result = "{\"isIncomplete\":false,\"items\":["
  var labels = initHashSet[string]()
  var first = true
  if doc.memberCompletionAt(line, character):
    # A member: what can follow the `.` is the receiver's members, which sem
    # records from the receiver's established type. The scope chain and the import
    # type's -- so only the dot's own rows are offered. Reading `visible` here
    # returns the whole scope chain, which is the answer 2v2 exists to replace.
    # type's -- so only the cursor query's rows are offered.
    for symbol in query.dotMembers:
      let name = symbol.name
      if name.len == 0 or name in labels: continue
      labels.incl name
      if not first: result.add ','
      first = false
      let kind = if symbol.kind in ["proc", "func", "iterator", "method",
                                    "template", "macro", "converter"]: 3 else: 20
      result.add "{\"label\":" & quoteJson(name) & ",\"kind\":" & $kind &
        ",\"detail\":" & quoteJson(symbol.kind) & "}"
    result.add "]}"
    return
  if query.documentMode:
    # Document mode records the module's import table once instead of the scope
    # chain at a cursor, so offer those names and let the lexical index supply
    # the ones local to this scope.
    for symbol in query.imports:
      let name = symbol.name
      if name in labels: continue
      labels.incl name
      if not first: result.add ','
      first = false
      let kind = if symbol.kind in ["proc", "func", "iterator", "method",
                                    "template", "macro", "converter"]: 3 else: 6
      result.add "{\"label\":" & quoteJson(name) & ",\"kind\":" & $kind &
        ",\"detail\":" & quoteJson(symbol.kind) & "}"
    for id in doc.visible(line, character):
      let n = doc.nodes[id]
      if n.text in labels: continue
      labels.incl n.text
      if not first: result.add ','
      first = false
      let kind = if n.declarationKind in ["proc", "func", "iterator", "method"]: 3 else: 6
      result.add "{\"label\":" & quoteJson(n.text) & ",\"kind\":" & $kind &
        ",\"detail\":" & quoteJson(n.declarationKind) & "}"
  elif query.queried and query.matched:
    for symbol in query.visible:
      let name = symbol.name
      if name in labels: continue
      labels.incl name
      if not first: result.add ','
      first = false
      let kind = if symbol.kind in ["proc", "func", "iterator", "method",
                                    "template", "macro", "converter"]: 3 else: 6
      result.add "{\"label\":" & quoteJson(name) & ",\"kind\":" & $kind &
        ",\"detail\":" & quoteJson(symbol.kind) & "}"
  else:
    for id in doc.visible(line, character):
      let n = doc.nodes[id]
      if n.text in labels: continue
      labels.incl n.text
      if not first: result.add ','
      first = false
      let kind = if n.declarationKind in ["proc", "func", "iterator", "method"]: 3 else: 6
      result.add "{\"label\":" & quoteJson(n.text) & ",\"kind\":" & $kind &
        ",\"detail\":" & quoteJson(n.declarationKind) & "}"
  result.add "]}"

proc signatureHelpJson(query: SemanticSnapshot): string =
  ## LSP's `SignatureHelp`: one entry per surviving overload, each a label plus its
  ## parameters. Types only -- a parameter without its name is a worse popup than a
  ## wrong one, and the names need the `CallArg` widening (see the 2v2 note).
  ##
  ## `signatures: []` is a real answer, not a failure: the cursor is not in a call,
  ## or every overload is provably out.
  result = "{\"signatures\":["
  var first = true
  for sig in query.signatures:
    if not first: result.add ','
    first = false
    let label = sig.name & "(" & sig.params & ")"
    result.add "{\"label\":" & quoteJson(label) & ",\"parameters\":["
    var firstParam = true
    for param in sig.params.split(","):
      let text = param.strip
      if text.len == 0: continue
      if not firstParam: result.add ','
      firstParam = false
      result.add "{\"label\":" & quoteJson(text) & "}"
    result.add "]}"
  result.add "],\"activeSignature\":0,\"activeParameter\":0}"

proc referencesJson(locations: seq[ReferenceLocation]): string =
  ## LSP's `textDocument/references`: a flat `Location[]`.
  ##
  ## `[]` is a real answer and not a failure -- the cursor resolved to nothing, or
  ## nothing else refers to it. Editors show that as "no results", which is the
  ## truth.
  result = "["
  var first = true
  for location in locations:
    if not first: result.add ','
    first = false
    result.add "{\"uri\":" & quoteJson(location.uri) &
      ",\"range\":" & rangeJson(location.range) & "}"
  result.add ']'

proc handle*(db: var Database; body: string): HandlerResult {.raises.} =
  result = HandlerResult(response: "", notification: "", stop: false)
  var parsed = parseJson(body)
  let msg = parsed.root
  # A malformed message must not take the server down with it: an editor that
  # sends garbage gets silence, not a crash.
  if msg.isEmpty or kind(msg) != JObject: return
  let methodName = msg.strField("method")
  let params = field(msg, "params")
  let idNode = field(msg, "id")
  let idPresent = hasField(msg, "id")
  let idText = if idPresent: rpcId(idNode) else: "null"
  case methodName
  of "initialize":
    let rootPath = stringField(params, "rootPath")
    let rootUri = stringField(params, "rootUri")
    let root = if rootPath.len > 0: rootPath
               elif rootUri.len > 0: uriPath(rootUri)
               else: db.root
    db = initDatabase(root)
    result.response = "{\"jsonrpc\":\"2.0\",\"id\":" & idText &
      ",\"result\":{\"capabilities\":{\"textDocumentSync\":1," &
      "\"completionProvider\":{\"resolveProvider\":false}," &
      "\"hoverProvider\":true,\"definitionProvider\":true," &
      "\"referencesProvider\":true," &
      "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}}," &
      "\"serverInfo\":{\"name\":\"nimony-lsp\",\"version\":\"0.1\"}}}"
  of "textDocument/didOpen", "textDocument/didChange":
    let td = field(params, "textDocument")
    let uriText = td.strField("uri")
    # No URI means no path, and the compiler would be handed an empty file to
    # resolve: reject it here rather than pay for a run that cannot succeed.
    if uriText.len == 0: return
    var source = td.strField("text")
    if methodName == "textDocument/didChange":
      if hasField(params, "contentChanges"):
        let changes = field(params, "contentChanges")
        if kind(changes) == JArray:
          for change in items(changes): source = change.strField("text")
    let version = int(td.intField("version"))
    var doc = db.updateDocument(uriText, uriPath(uriText), version, source)
    db.runDiagnostics(doc)
    result.notification = publishDiagnostics(doc)
  of "textDocument/didClose":
    let uriText = field(params, "textDocument").strField("uri")
    db.closeDocument(uriText)
    result.notification = "{\"jsonrpc\":\"2.0\",\"method\":" &
      "\"textDocument/publishDiagnostics\",\"params\":{\"uri\":" &
      quoteJson(uriText) & ",\"diagnostics\":[]}}"
  of "textDocument/completion", "textDocument/hover", "textDocument/definition",
     "textDocument/signatureHelp", "textDocument/references":
    let uriText = field(params, "textDocument").strField("uri")
    let doc = db.document(uriText)
    var value = "null"
    if doc != nil:
      let pos = docPosition(params)
      # The syntax node under the cursor. Only the four requests that answer about
      # THIS position need it, and asking for it first -- tying every query to a
      # node id -- threw away every semantic answer for the member name in
      # `node.isEmpty`, where the syntax side has no node under the cursor at all
      # because the name is only reachable through the `dot`. That is most call
      # sites in practice.
      let nodeId = if methodName == "textDocument/references": -1
                   else: doc.nodeAt(pos.line, pos.character)
      let memberRequest = methodName == "textDocument/completion" and
                       doc.memberCompletionAt(pos.line, pos.character)
      # Signature help is a request that must not be answered from the recorded
      # occurrences: sem only records which overloads survive for a cursor query, and
      # mid-call there is no identifier at the cursor to look up.
      let signatureRequest = methodName == "textDocument/signatureHelp"
      case methodName
      of "textDocument/references":
        # References is a request that must not be answered from them either, and
        # for the opposite reason: the OTHER occurrences are the answer, so it reads
        # the whole snapshot rather than one position of it. Handing it to
        # `ideQueryAt` would have answered a question nobody asked and thrown the
        # answer away. A third kind of request rather than another flag on the two
        # above, because what it skips is the lookup and not just the scope walk.
        value = referencesJson(db.referencesAt(doc, pos.line, pos.character,
          boolField(field(params, "context"), "includeDeclaration", true)))
      of "textDocument/completion":
        value = completionJson(doc, pos.line, pos.character,
          db.ideQueryAt(doc, pos.line, pos.character, memberRequest, false))
      of "textDocument/hover":
        value = hoverJson(doc, nodeId,
          db.ideQueryAt(doc, pos.line, pos.character, false, false))
      of "textDocument/signatureHelp":
        value = signatureHelpJson(db.ideQueryAt(doc, pos.line, pos.character, false,
                                                signatureRequest))
      else:
        value = definitionJson(doc, nodeId,
          db.ideQueryAt(doc, pos.line, pos.character, false, false))
    result.response = "{\"jsonrpc\":\"2.0\",\"id\":" & idText &
      ",\"result\":" & value & "}"
  of "shutdown":
    result.response = "{\"jsonrpc\":\"2.0\",\"id\":" & idText & ",\"result\":null}"
  of "exit":
    result.stop = true
  of "initialized": discard
  else:
    if idPresent:
      result.response = "{\"jsonrpc\":\"2.0\",\"id\":" & idText &
        ",\"error\":{\"code\":-32601,\"message\":" &
        quoteJson("Method not found: " & methodName) & "}}"
