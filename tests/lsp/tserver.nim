import std / [assertions, os, strutils, syncio, uri]
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
  let openedDocs = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-docs.nim","languageId":"nim","version":1,"text":"proc double*(x: int): int =\n  ## Doubles x.\n  ##\n  ## Second line.\n  x * 2\n\nproc use() =\n  discard double(2)\n"}}}""")
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

  # A `./`-less sibling import has to keep working. The root is handed to sem as
  # a pre-parsed `.nif` under the cache dir, so the root's directory is the cache
  # dir and not the source tree -- which is exactly where `import sibling_helper`
  # used to resolve to nothing. The symptom was not a missing hover but a build
  # that died on `cannot open: <mod>.s.nif`, published to the editor as an empty
  # diagnostic list, so these assertions pin both halves: no failure notice, and
  # a definition that really lands in the sibling file.
  #
  # A relative URI is passed through `uriPath` unchanged, which keeps the
  # messages literal and exercises the relative-vs-absolute path comparison in
  # the compiler at the same time.
  assert readFile("tests/lsp/fixtures/sibling_dep.nim").replace("\r\n", "\n") ==
    "import sibling_dep_helper\n\nproc useSibling*(): int =\n  siblingAnswer()\n"
  let sibOpened = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"tests/lsp/fixtures/sibling_dep.nim","languageId":"nim","version":1,"text":"import sibling_dep_helper\n\nproc useSibling*(): int =\n  siblingAnswer()\n"}}}""")
  assert not sibOpened.notification.contains("semantic analysis failed"),
         "the sibling module's compile failed: " & sibOpened.notification
  assert db.document("tests/lsp/fixtures/sibling_dep.nim").snapshot.positions.len > 0,
         "the sibling document recorded no identifier occurrences"

  let sibHover = handle(db, """{"jsonrpc":"2.0","id":90,"method":"textDocument/hover","params":{"textDocument":{"uri":"tests/lsp/fixtures/sibling_dep.nim"},"position":{"line":3,"character":3}}}""")
  assert sibHover.response.contains("siblingAnswer"),
         "no hover for the sibling's symbol: " & sibHover.response

  let sibDef = handle(db, """{"jsonrpc":"2.0","id":91,"method":"textDocument/definition","params":{"textDocument":{"uri":"tests/lsp/fixtures/sibling_dep.nim"},"position":{"line":3,"character":3}}}""")
  assert sibDef.response.contains("sibling_dep_helper.nim"),
         "definition did not reach the sibling: " & sibDef.response

  # Hover documentation comes from the parser, not from a scan of the text. The
  # text used to be re-read with a line walk, which could not see a `##[` block
  # and had to be fooled about indentation; the parser merges the block, strips
  # it and hands it over, so the awkward shapes come out right for free. A `#`
  # comment is not documentation and must stay invisible.
  #
  # Keyed by the line the block ENDS on, so a declaration is documented exactly
  # when the line above it is where its comment finished.
  # An absolute `file://` URI, which is what an editor actually sends. A bare
  # relative path parses and indexes but does not resolve through hover.
  let docFixturePath = getCurrentDir() / "tests" / "lsp" / "fixtures" /
    "documented.nim"
  let docFixtureUri = "file://" & docFixturePath
  let docFixtureText = readFile(docFixturePath).replace("\r\n", "\n")
  # Built with escaped quotes rather than by splicing triple-quoted literals:
  # a `"""` ending next to a `"` loses the quote, which silently unquotes the
  # URI and makes the whole message unparseable.
  let docFixtureMsg = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & docFixtureUri &
    "\",\"languageId\":\"nim\",\"version\":1,\"text\":\"" &
    docFixtureText.replace("\n", "\\n") & "\"}}}"
  let docFixtureOpened = handle(db, docFixtureMsg)
  assert not docFixtureOpened.notification.contains("semantic analysis failed"),
         "the documented fixture failed to compile: " & docFixtureOpened.notification
  let docFixtureDoc = db.document(docFixtureUri)
  assert docFixtureDoc != nil,
         "document not stored: " & docFixtureOpened.response & " / " &
         docFixtureOpened.notification
  let docFixtureComments = docFixtureDoc.docComments
  # The module header, the one documented field, `simple`, `twoParagraphs`,
  # `blockDoc`, `usesBodyDoc` and the trailing block after `inlineDoc`'s body.
  # Nothing else: the `#` comments and `undocumented` and `nested` have none.
  assert docFixtureComments.len == 7,
         "recorded " & $docFixtureComments.len & " doc comments, expected 7"
  # A `#` comment is not a doc comment, and the two-paragraph and `##[` blocks
  # keep the blank line and the shape the author wrote.
  assert docFixtureComments.getOrDefault(9, "").len == 0
  assert docFixtureComments.getOrDefault(22, "").contains("- one")
  assert docFixtureComments.getOrDefault(27, "").contains("It spans lines")
  assert docFixtureComments.getOrDefault(35, "") ==
    "Documents this declaration, not the next one."
  assert docFixtureComments.getOrDefault(2, "").contains("Second line of it.")
  assert docFixtureComments.getOrDefault(13, "") == "A simple one-line doc."
  assert docFixtureComments.getOrDefault(7, "").contains("field's own documentation")
  # `undocumented` sits under a `#` comment (line 30) and `nested` under
  # nothing (line 40), so neither line is a key.
  assert not docFixtureComments.hasKey(30)
  assert not docFixtureComments.hasKey(40)

  let dd = db.document(docFixtureUri)
  let simpleHover = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":95,\"method\":\"textDocument/hover\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & docFixtureUri &
    "\"},\"position\":{\"line\":11,\"character\":7}}}")
  assert simpleHover.response.contains("A simple one-line doc."),
         "hover lost the doc comment: " & simpleHover.response
  # A `##` block is the documentation of the declaration it follows as the first
  # statement of the body's, and of nothing else. `usesBodyDoc`'s block sits
  # under `usesBodyDoc` and above `nested`, so it belongs to `usesBodyDoc` and
  # `nested` must stay undocumented.
  let nestedHover = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":96,\"method\":\"textDocument/hover\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & docFixtureUri &
    "\"},\"position\":{\"line\":39,\"character\":7}}}")
  assert not nestedHover.response.contains("Documents this declaration"),
         "a later declaration took the block above it: " & nestedHover.response

try:
  runTests()
except:
  assert false, "LSP handler test raised unexpectedly"
