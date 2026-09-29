## LSP request handlers. Resolution is lexical Phase 2v1: unresolved or
## type-dependent expressions return no result instead of guessing.

{.feature: "lenientnils".}

import std / [json, strutils, uri, sets]
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

proc field(node: JsonNode; name: string): JsonNode =
  if kind(node) != JObject: return JsonNode()
  for key, value in pairs(node):
    if key == name: return value
  result = JsonNode()

proc hasField(node: JsonNode; name: string): bool =
  if kind(node) != JObject: return false
  for key, value in pairs(node):
    if key == name: return true
  result = false

proc stringField(node: JsonNode; name: string): string =
  if node.hasField(name): getStr(field(node, name))
  else: ""

proc rpcId(node: JsonNode): string =
  case kind(node)
  of JInt: $getInt(node)
  of JString: quoteJson(getStr(node))
  else: "null"

proc posJson(line, character: int): string =
  "{\"line\":" & $line & ",\"character\":" & $character & "}"

proc rangeJson(r: SourceRange): string =
  "{\"start\":" & posJson(r.startLine, r.startCharacter) &
    ",\"end\":" & posJson(r.endLine, r.endCharacter) & "}"

proc diagnosticsJson(doc: Document): string =
  result = "["
  for i, d in doc.diagnostics:
    if i > 0: result.add ','
    let line = max(0, d.line - 1)
    let col = max(0, d.col)
    result.add "{\"range\":{\"start\":" & posJson(line, col) &
      ",\"end\":" & posJson(line, col + 1) &
      "},\"severity\":1,\"source\":\"nimony\",\"message\":" &
      quoteJson(d.message) & "}"
  result.add ']'

proc uriPath(uriText: string): string {.raises.} =
  if uriText.startsWith("file://"): decodeUrl(uriText[7 .. ^1])
  else: uriText

proc publishDiagnostics(doc: Document): string =
  "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{" &
    "\"uri\":" & quoteJson(doc.uri) & ",\"diagnostics\":" &
    diagnosticsJson(doc) & "}}"

proc docPosition(params: JsonNode): tuple[line, character: int] =
  let pos = field(params, "position")
  (int(getInt(field(pos, "line"))), int(getInt(field(pos, "character"))))

proc definitionJson(doc: Document; nodeId: int): string =
  result = "["
  let resolved = doc.resolve(nodeId)
  for i, id in resolved:
    if i > 0: result.add ','
    let n = doc.nodes[id]
    result.add "{\"uri\":" & quoteJson(doc.uri) &
      ",\"range\":" & rangeJson(n.range) & "}"
  result.add ']'

proc hoverJson(doc: Document; nodeId: int): string =
  let resolved = doc.resolve(nodeId)
  if resolved.len == 0: return "null"
  let n = doc.nodes[resolved[0]]
  let kindName = if n.declarationKind.len > 0: n.declarationKind else: "symbol"
  "{\"contents\":{\"kind\":\"markdown\",\"value\":" &
    quoteJson("`" & kindName & " " & n.text & "`") &
    "},\"range\":" & rangeJson(doc.nodes[nodeId].range) & "}"

proc completionJson(doc: Document; line, character: int): string =
  if doc.isMemberAccess(line, character):
    return "{\"isIncomplete\":false,\"items\":[]}"
  result = "{\"isIncomplete\":false,\"items\":["
  let visible = doc.visible(line, character)
  var labels = initHashSet[string]()
  var first = true
  for id in visible:
    let n = doc.nodes[id]
    if n.text in labels: continue
    labels.incl n.text
    if not first: result.add ','
    first = false
    let kind = if n.declarationKind in ["proc", "func", "iterator", "method"]: 3 else: 6
    result.add "{\"label\":" & quoteJson(n.text) & ",\"kind\":" & $kind &
      ",\"detail\":" & quoteJson(n.declarationKind) & "}"
  result.add "]}"

proc handle*(db: var Database; body: string): HandlerResult {.raises.} =
  result = HandlerResult(response: "", notification: "", stop: false)
  var parsed = parseJson(body)
  let msg = parsed.root
  let methodName = getStr(field(msg, "method"))
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
      "\"hoverProvider\":true,\"definitionProvider\":true}," &
      "\"serverInfo\":{\"name\":\"nimony-lsp\",\"version\":\"0.1\"}}}"
  of "textDocument/didOpen", "textDocument/didChange":
    let td = field(params, "textDocument")
    let uriText = getStr(field(td, "uri"))
    var source = stringField(td, "text")
    if methodName == "textDocument/didChange":
      if hasField(params, "contentChanges"):
        let changes = field(params, "contentChanges")
        if kind(changes) == JArray:
          for change in items(changes): source = getStr(field(change, "text"))
    let version = int(getInt(field(td, "version")))
    let doc = db.updateDocument(uriText, uriPath(uriText), version, source)
    result.notification = publishDiagnostics(doc)
  of "textDocument/didClose":
    let uriText = getStr(field(field(params, "textDocument"), "uri"))
    db.closeDocument(uriText)
    result.notification = "{\"jsonrpc\":\"2.0\",\"method\":" &
      "\"textDocument/publishDiagnostics\",\"params\":{\"uri\":" &
      quoteJson(uriText) & ",\"diagnostics\":[]}}"
  of "textDocument/completion", "textDocument/hover", "textDocument/definition":
    let uriText = getStr(field(field(params, "textDocument"), "uri"))
    let doc = db.document(uriText)
    var value = "null"
    if doc != nil:
      let pos = docPosition(params)
      let nodeId = doc.nodeAt(pos.line, pos.character)
      case methodName
      of "textDocument/completion": value = completionJson(doc, pos.line, pos.character)
      of "textDocument/hover": value = hoverJson(doc, nodeId)
      else: value = definitionJson(doc, nodeId)
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
