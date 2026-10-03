import std / [assertions, os, strutils, uri]
import ../../src/lsp/[database, handlers]

proc uriPathForTest(uriText: string): string {.raises.} =
  ## The handler's decode step, so the test exercises the real round trip.
  if not uriText.startsWith("file://"): return uriText
  var rest = uriText[7 .. ^1]
  if rest.len > 0 and rest[0] != '/': return decodeUrl(rest)
  rest = decodeUrl(rest)
  if rest.len >= 3 and rest[0] == '/' and rest[1] in {'a'..'z', 'A'..'Z'} and
      rest[2] == ':':
    return rest[1 .. ^1]
  rest

proc runTests() {.raises.} =
  var db = initDatabase(getCurrentDir())

  # A definition into another module hands the client a URI. It has to be one
  # the client can open, so separators are normalized and reserved characters
  # are percent-encoded -- and encoding must not depend on what the HOST thinks
  # is absolute, or a Windows path gets grafted onto the workspace root.
  let uriDoc = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/plain.nim","version":1,"text":"let x = 1\n"}}}""")
  discard uriDoc
  let plain = db.document("file:///workspace/plain.nim")
  let cases = [
    ("C:/Users/x/a.nim", "file:///C:/Users/x/a.nim"),
    ("C:\\Users\\x\\a.nim", "file:///C:/Users/x/a.nim"),
    ("\\\\server\\share\\a.nim", "file:////server/share/a.nim"),
    ("/abs/with space/x.nim", "file:///abs/with%20space/x.nim"),
    ("/abs/hash#f.nim", "file:///abs/hash%23f.nim"),
    ("/abs/percent%20/x.nim", "file:///abs/percent%2520/x.nim"),
    ("lib/std/strutils.nim", "file://" & getCurrentDir() & "/lib/std/strutils.nim")]
  for id in 0 ..< cases.len:
    let uri = plain.uriForPath(cases[id][0])
    assert uri == cases[id][1], "encode " & cases[id][0] & " -> " & uri
    # A relative path resolves against the workspace root, so what comes back
    # is the absolute form -- that is the point of resolving it.
    var want = cases[id][0].replace('\\', '/')
    if not want.isAbsolute and want[1] != ':': want = getCurrentDir() / want
    assert uriPathForTest(uri) == want, "round trip " & uri
  # Incoming URIs decode to a usable path, drive letter included.
  let incoming = [("file:///workspace/plain.nim", "/workspace/plain.nim"),
                  ("file:///C:/Users/x/a.nim", "C:/Users/x/a.nim"),
                  ("file:///c%3A/Users/x/a.nim", "c:/Users/x/a.nim"),
                  ("file:///workspace/with%20space/a.nim", "/workspace/with space/a.nim"),
                  ("file:///workspace/back%5Cslash/a.nim", "/workspace/back\\slash/a.nim")]
  for id in 0 ..< incoming.len:
    let decoded = uriPathForTest(incoming[id][0])
    assert decoded == incoming[id][1], "decode " & incoming[id][0] & " -> " & decoded
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/plain.nim"}}}""")

  # A peer that sends nonsense gets silence, never a dead server: every
  # accessor runs against whatever the peer actually sent.
  for bad in ["", "garbage", "[]", """{"method":123}""",
              """{"method":"textDocument/didOpen"}""",
              """{"method":"textDocument/didChange"}""",
              """{"method":"textDocument/hover","params":5}""",
              """{"method":"textDocument/definition","params":{"textDocument":{},"position":{}}}""",
              """{"method":"textDocument/completion","params":{"textDocument":null}}""",
              """{"method":"textDocument/didClose"}"""]:
    discard handle(db, bad)

  let docUri = "file:///workspace/lsp-docs.nim"
  let openedDocs = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-docs.nim","languageId":"nim","version":1,"text":"## Doubles x.\n##\n## Second line.\nproc double*(x: int): int =\n  x * 2\n\nproc use() =\n  discard double(2)\n"}}}""")
  let docsHover = handle(db, """{"jsonrpc":"2.0","id":20,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/lsp-docs.nim"},"position":{"line":7,"character":12}}}""")
  assert docsHover.response.contains("proc double")
  assert docsHover.response.contains("Doubles x.")
  assert docsHover.response.contains("Second line.")
  discard openedDocs
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-docs.nim"}}}""")

  let uri = "file:///workspace/lsp-test.nim"
  let opened = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim","version":1,"text":"let broken = (1\nlet typedBroken: UnknownType = 1\nimport std/strutils\nlet global = 1\nproc f() =\n  let global = 2\n  let local = global\n  let found = contains(\"x\", \"x\")\n  local\n  global.\n  \n"}}}""")
  assert opened.notification.contains("publishDiagnostics")
  assert opened.notification.contains("expected")

  let definition = handle(db, """{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":8,"character":3}}}""")
  assert definition.response.contains("\"line\":6")
  assert definition.response.contains("\"character\":6")

  let shadowed = handle(db, """{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":6,"character":16}}}""")
  assert shadowed.response.contains("\"line\":5")
  assert shadowed.response.contains("\"character\":6")

  let importedDefinition = handle(db, """{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":7,"character":16}}}""")
  assert importedDefinition.response.contains("lib/std/strutils.nim")
  assert importedDefinition.response.contains("\"character\":5")

  let hover = handle(db, """{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":8,"character":3}}}""")
  assert hover.response.contains("let local")

  # Document mode records every occurrence, so a position the cursor has never
  # visited answers from the same snapshot instead of a fresh compile.
  let doc = db.document(uri)
  assert doc.snapshot.positions.len > 0
  # The shapes that a one-at-a-time capture never saw: a parameter name in a
  # signature, a field chosen through a dot, and a name imported from another
  # module. Each answers from the recorded positions without a fresh compile.
  # The fixture uses `f()` with parameters `global` and `local`, and imports
  # `contains`; all three are occurrences the one-at-a-time capture never saw.
  var sawParam = false
  var sawImported = false
  for position in doc.snapshot.positions:
    if position.name == "local" and position.symbols.len > 0: sawParam = true
    if position.name == "contains" and position.symbols.len > 0: sawImported = true
  assert sawParam, "a local's use was not recorded"
  assert sawImported, "an imported name's use was not recorded"
  # The shapes the one-at-a-time capture missed: a parameter in a signature, a
  # field selected through a dot, and a type name from an import.
  var sawUnresolved = false
  for position in doc.snapshot.positions:
    if position.symbols.len == 0: sawUnresolved = true
  assert sawUnresolved
  let revisited = handle(db, """{"jsonrpc":"2.0","id":21,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":8,"character":3}}}""")
  assert revisited.response.contains("let local")

  let semanticCompletion = handle(db, """{"jsonrpc":"2.0","id":5,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":8,"character":3}}}""")
  assert semanticCompletion.response.contains("\"label\":\"local\"")
  assert semanticCompletion.response.contains("\"label\":\"global\"")
  assert semanticCompletion.response.contains("\"label\":\"contains\"")

  let postDot = handle(db, """{"jsonrpc":"2.0","id":6,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":9,"character":9}}}""")
  assert postDot.response.contains("\"items\":[]")

  let completion = handle(db, """{"jsonrpc":"2.0","id":7,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":10,"character":2}}}""")
  assert completion.response.contains("\"label\":\"local\"")
  assert completion.response.contains("\"label\":\"global\"")

  # A semantic error reaches the editor even though nothing points at it.
  assert opened.notification.contains("undeclared identifier") or
         opened.notification.contains("UnknownType")

  let cacheFile = db.document(uri).cacheFile
  assert cacheFile.contains("nimcache/lsp")
  let changed = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim","version":2},"contentChanges":[{"text":"let replacement = 7\n"}]}}""")
  assert changed.notification.contains("publishDiagnostics")
  assert db.document(uri).version == 2
  assert db.document(uri).nodes.len > 0

  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"}}}""")
  assert db.document(uri) == nil
  assert not fileExists(cacheFile)

try:
  runTests()
except:
  assert false, "LSP handler test raised unexpectedly"
