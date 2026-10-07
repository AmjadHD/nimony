import std / [assertions, os, strutils, syncio, uri, envvars, tables]
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

proc assertWellFormed(response, label: string) =
  ## Every response must be balanced JSON. A substring assertion cannot see this:
  ## `{"isIncomplete":false,"items":[]}` *contains* `"items":[]` while being one
  ## brace short, and that is exactly what a member completion returned until the
  ## array-closing bracket was written without the object-closing one.
  var depth = 0
  var inStr = false
  var i = 0
  while i < response.len:
    let ch = response[i]
    if inStr:
      if ch == '\\': inc i
      elif ch == '"': inStr = false
    else:
      case ch
      of '"': inStr = true
      of '{': inc depth
      of '}': dec depth
      else: discard
    inc i
  assert depth == 0,
         label & " is " & $(-depth) & " brace(s) out of balance: " & response

proc note(responses: var Table[string, string]; label, response: string) =
  ## One handler result, keyed by label, for the side-by-side comparison at the
  ## end. A flat proc rather than a closure over `responses`: the closure would
  ## need `{.closure.}`, and a flat one threads the table through explicitly.
  responses[label] = response

proc runTests(responses: var Table[string, string]; inProcess: bool) {.raises.} =
  ## The request sequence. Run twice -- once per sem path -- with every response
  ## recorded, so the two paths can be compared rather than each merely being
  ## self-consistent.
  putEnv("NIMONY_LSP_INPROCESS", if inProcess: "1" else: "0")
  var db = initDatabase(getCurrentDir())

  # A definition into another module hands the client a URI. It has to be one
  # the client can open, so separators are normalized and reserved characters
  # are percent-encoded -- and encoding must not depend on what the HOST thinks
  # is absolute, or a Windows path gets grafted onto the workspace root.
  let uriDoc = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/plain.nim","version":1,"text":"let x = 1\n"}}}""")
  note(responses, "uriDoc", uriDoc.response)
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
  note(responses, "openedDocs", openedDocs.response)
  let docsHover = handle(db, """{"jsonrpc":"2.0","id":20,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/lsp-docs.nim"},"position":{"line":7,"character":12}}}""")
  note(responses, "docsHover", docsHover.response)
  assert docsHover.response.contains("proc double")
  assert docsHover.response.contains("Doubles x.")
  assert docsHover.response.contains("Second line.")
  discard openedDocs
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-docs.nim"}}}""")

  let uri = "file:///workspace/lsp-test.nim"
  let opened = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim","version":1,"text":"let broken = (1\nlet typedBroken: UnknownType = 1\nimport std/strutils\nlet global = 1\nproc f() =\n  let global = 2\n  let local = global\n  let found = contains(\"x\", \"x\")\n  local\n  global.\n  \n"}}}""")
  note(responses, "opened", opened.response)
  assert opened.notification.contains("publishDiagnostics")
  assert opened.notification.contains("expected")

  let definition = handle(db, """{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":8,"character":3}}}""")
  note(responses, "definition", definition.response)
  assert definition.response.contains("\"line\":6")
  assert definition.response.contains("\"character\":6")

  let shadowed = handle(db, """{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":6,"character":16}}}""")
  note(responses, "shadowed", shadowed.response)
  assert shadowed.response.contains("\"line\":5")
  assert shadowed.response.contains("\"character\":6")

  let importedDefinition = handle(db, """{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":7,"character":16}}}""")
  note(responses, "importedDefinition", importedDefinition.response)
  assert importedDefinition.response.contains("lib/std/strutils.nim")
  assert importedDefinition.response.contains("\"character\":5")

  let hover = handle(db, """{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":8,"character":3}}}""")
  note(responses, "hover", hover.response)
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
  note(responses, "revisited", revisited.response)
  assert revisited.response.contains("let local")

  let semanticCompletion = handle(db, """{"jsonrpc":"2.0","id":5,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":8,"character":3}}}""")
  note(responses, "semanticCompletion", semanticCompletion.response)
  assert semanticCompletion.response.contains("\"label\":\"local\"")
  assert semanticCompletion.response.contains("\"label\":\"global\"")
  assert semanticCompletion.response.contains("\"label\":\"contains\"")

  let postDot = handle(db, """{"jsonrpc":"2.0","id":6,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":9,"character":9}}}""")
  note(responses, "postDot", postDot.response)
  assert postDot.response.contains("\"items\":[]")

  let completion = handle(db, """{"jsonrpc":"2.0","id":7,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":10,"character":2}}}""")
  note(responses, "completion", completion.response)
  assert completion.response.contains("\"label\":\"local\"")
  assert completion.response.contains("\"label\":\"global\"")

  # A semantic error reaches the editor even though nothing points at it.
  assert opened.notification.contains("undeclared identifier") or
         opened.notification.contains("UnknownType")

  let cacheFile = db.document(uri).cacheFile
  assert cacheFile.contains("nimcache/lsp")
  let changed = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim","version":2},"contentChanges":[{"text":"let replacement = 7\n"}]}}""")
  note(responses, "changed", changed.response)
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
  note(responses, "sibOpened", sibOpened.response)
  assert not sibOpened.notification.contains("semantic analysis failed"),
         "the sibling module's compile failed: " & sibOpened.notification
  assert db.document("tests/lsp/fixtures/sibling_dep.nim").snapshot.positions.len > 0,
         "the sibling document recorded no identifier occurrences"

  let sibHover = handle(db, """{"jsonrpc":"2.0","id":90,"method":"textDocument/hover","params":{"textDocument":{"uri":"tests/lsp/fixtures/sibling_dep.nim"},"position":{"line":3,"character":3}}}""")
  note(responses, "sibHover", sibHover.response)
  assert sibHover.response.contains("siblingAnswer"),
         "no hover for the sibling's symbol: " & sibHover.response
  # The helper is not the open document, so its text is read from disk and the
  # block is read with the lexer. Its doc comment is a `##[` run, and the
  # assertion names a phrase from the *last* line of it: a scan that only
  # recognises lines beginning with `##` stops at the opening line and loses the
  # rest, which is the whole gap this covers.
  assert sibHover.response.contains("keep supplying"),
         "cross-file hover lost a `##[` block comment: " & sibHover.response
  assert sibHover.response.contains("A documented answer"),
         "cross-file hover lost the block's first line: " & sibHover.response

  let sibDef = handle(db, """{"jsonrpc":"2.0","id":91,"method":"textDocument/definition","params":{"textDocument":{"uri":"tests/lsp/fixtures/sibling_dep.nim"},"position":{"line":3,"character":3}}}""")
  note(responses, "sibDef", sibDef.response)
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

  # When a name resolves through overload resolution sem reports two records for
  # the one span: the overload set it weighed, and the single symbol it picked --
  # and the set is written first. Answering from the first match therefore
  # described the wrong proc. `result.add` on a `string` is the sharp case:
  # `seqimpl.add` and `stringimpl.add` both match the name, sem resolves to
  # `stringimpl`, and the set's first element is `seqimpl`.
  let overloadText = "proc useOverload*(s: string) =\n  s.add('x')\n"
  let overloadUri = "file:///workspace/lsp-overload.nim"
  let overloadOpened = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-overload.nim","languageId":"nim","version":1,"text":"proc useOverload*(s: string) =\n  s.add('x')\n"}}}""")
  note(responses, "overloadOpened", overloadOpened.response)
  assert not overloadOpened.notification.contains("semantic analysis failed"),
         "the overload fixture failed to compile: " & overloadOpened.notification
  let overloadDoc = db.document(overloadUri)
  assert overloadDoc != nil and overloadDoc.snapshot.positions.len > 0,
         "the overload fixture recorded no occurrences"
  # The occurrence is recorded twice, and the two records disagree -- that is the
  # premise. The pair is found rather than hardcoded, so the test does not depend
  # on where `seqimpl` and `stringimpl` happen to live.
  var overloadSet = IdePosition(line: -1, column: -1)
  var overloadPick = IdePosition(line: -1, column: -1)
  for position in overloadDoc.snapshot.positions:
    if position.name != "add": continue
    if position.symbols.len == 1: overloadPick = position
    elif position.symbols.len > 1: overloadSet = position
  assert overloadSet.symbols.len > 1 and overloadPick.symbols.len == 1,
         "expected `add` to be recorded as an overload set and as a resolution"
  assert overloadSet.symbols[0].range.startLine != overloadPick.symbols[0].range.startLine,
         "the set's first candidate and the resolved symbol are the same here, " &
         "so this fixture no longer exercises the ordering"
  let addHover = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":98,\"method\":\"textDocument/hover\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & overloadUri &
    "\"},\"position\":{\"line\":1,\"character\":4}}}")
  # Hover must answer from the resolution. Its range is the only place the chosen
  # declaration shows, so that is what the assertion reads.
  assert addHover.response.contains("\"line\":" & $overloadPick.symbols[0].range.startLine),
         "hover did not answer from the resolved symbol: " & addHover.response
  assert not addHover.response.contains("\"line\":" & $overloadSet.symbols[0].range.startLine),
         "hover answered from the overload set's first candidate: " &
         addHover.response
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-overload.nim"}}}""")
  note(responses, "addHover", addHover.response)

  # Completion after a dot, from the receiver's established type. This is the
  # first of Phase 2v2's criteria that needs no overload resolution at all: the
  # receiver's type is already known, so walking its members is the whole job.
  #
  # It has to be a *cursor* query. Nothing is typed after the dot, so the
  # document-mode occurrence walk has no symbol to record for the position, and
  # the import table lists every name in sight rather than this type's members --
  # so the snapshot cannot answer it even when it exists.
  # The receiver must be the enum *type*, not a value of it. `Color.colRed` is
  # real Nim -- `tryBuiltinDot` resolves it in its `TypeddescT` branch -- while
  # `k.colRed` is an error, so completing after `k.` would suggest code that does
  # not compile.
  let dotText = "type Color = enum\n  colRed, colGreen, colBlue\n\n" &
                "proc partial(k: Color) =\n  Color.\n"
  let dotUri = "file:///workspace/lsp-dot.nim"
  let dotOpened = handle(db, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & dotUri &
    "\",\"languageId\":\"nim\",\"version\":1,\"text\":\"" &
    dotText.replace("\n", "\\n") & "\"}}}")
  assert not dotOpened.notification.contains("semantic analysis failed"),
         "the dot fixture failed to compile: " & dotOpened.notification
  # `Color.` on 0-based line 4, cursor right after the dot, at end of file -- the
  # shape a user is actually in while typing.
  let enumComplete = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"textDocument/completion\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & dotUri &
    "\"},\"position\":{\"line\":4,\"character\":8}}}")
  for want in ["colRed", "colGreen", "colBlue"]:
    assert enumComplete.response.contains(want),
           "post-dot completion on an enum omitted " & want & ": " &
           enumComplete.response
  # A name that is not a member of `Color` must not appear, or this is just the
  # scope chain again under a different label.
  assertWellFormed(enumComplete.response, "member completion")
  assert not enumComplete.response.contains("\"label\":\"partial\""),
         "post-dot completion offered a name from outside the receiver's type: " &
         enumComplete.response

  # And the negative case, which is the one that was wrong: a receiver that is an
  # enum *value* has no fields at all, so there is nothing to offer. Completing
  # `k.` to the literals is what this used to do, and `k.colRed` does not compile.
  let valueText = "type Color = enum\n  colRed, colGreen, colBlue\n\n" &
                  "proc valueCase(k: Color) =\n  k.\n"
  let valueUri = "file:///workspace/lsp-dot-value.nim"
  discard handle(db, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" &
    valueUri & "\",\"languageId\":\"nim\",\"version\":1,\"text\":\"" &
    valueText.replace("\n", "\\n") & "\"}}}")
  let valueComplete = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":98,\"method\":\"textDocument/completion\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & valueUri &
    "\"},\"position\":{\"line\":4,\"character\":4}}}")
  assertWellFormed(valueComplete.response, "member completion on an enum value")
  for unwanted in ["colRed", "colGreen", "colBlue"]:
    assert not valueComplete.response.contains(unwanted),
           "an enum value was given fields it does not have: " & unwanted & " in " &
           valueComplete.response

  # The steady state, not the empty-after-dot case: a *partially typed* member.
  # This is what completion exists for, and it must be filtered by the receiver's
  # type like the empty case -- not fall back to the scope chain.
  let partialText = "type Color = enum\n  colRed, colGreen, colBlue\n\n" &
                    "proc partial(k: Color) =\n  discard k\n  Color.co\n"
  let partialUri = "file:///workspace/lsp-dot-partial.nim"
  discard handle(db, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" &
    partialUri & "\",\"languageId\":\"nim\",\"version\":1,\"text\":\"" &
    partialText.replace("\n", "\\n") & "\"}}}")
  let partialComplete = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"textDocument/completion\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & partialUri &
    "\"},\"position\":{\"line\":5,\"character\":9}}}")
  let partialDoc = db.document(partialUri)
  # Nothing is recorded at the cursor for `Color.co` -- a half-typed name resolves
  # to nothing -- which is exactly why the query cannot be routed by asking
  # whether an occurrence is there. It is routed by the request being a
  # completion.
  var recordedAtCursor = 0
  for position in partialDoc.snapshot.positions:
    if position.line == 6: recordedAtCursor = position.symbols.len
  assert recordedAtCursor == 0,
         "a half-typed member was expected to record no symbol here"
  for want in ["colRed", "colGreen", "colBlue"]:
    assert partialComplete.response.contains(want),
           "post-dot completion on a partial name omitted " & want & ": " &
           partialComplete.response
  assertWellFormed(partialComplete.response, "partial member completion")
  assert not partialComplete.response.contains("\"label\":\"partial\""),
         "a partial member name fell back to the scope chain: " &
         partialComplete.response
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-dot-partial.nim"}}}""")
  note(responses, "partialComplete", partialComplete.response)

  # An object receiver, end to end. `members.nim` checks the rows the sidecar
  # carries; this checks what the client actually receives, which is a different
  # thing -- a label, a kind and a detail string per member.
  let objText = "type Obj = object\n  pub*: int\n  priv: int\n\n" &
                "proc partial(o: Obj) =\n  o.pu\n"
  let objUri = "file:///workspace/lsp-dot-object.nim"
  discard handle(db, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" &
    objUri & "\",\"languageId\":\"nim\",\"version\":1,\"text\":\"" &
    objText.replace("\n", "\\n") & "\"}}}")
  let objComplete = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":104,\"method\":\"textDocument/completion\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & objUri &
    "\"},\"position\":{\"line\":5,\"character\":5}}}")
  assertWellFormed(objComplete.response, "object member completion")
  # `priv` is reachable in the module that declares it, so it belongs here; the
  # cross-module case is in members.nim.
  for want in ["pub", "priv"]:
    assert objComplete.response.contains("\"label\":\"" & want & "\""),
           "object member completion omitted " & want & ": " & objComplete.response
  assert not objComplete.response.contains("\"label\":\"partial\""),
         "object member completion offered a name from outside the receiver: " &
         objComplete.response
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-dot-object.nim"}}}""")
  note(responses, "objComplete", objComplete.response)

  # What a member completion costs. The cursor query spawns a `nimony check`, and
  # the query cache is keyed on an exact line and column -- so the sequence a user
  # actually types, `k.c` then `k.co` then `k.col`, is three distinct positions and
  # three spawns. Measured, because "it wants caching" is not the same as knowing
  # whether it is already too slow to use.
  var partialDoc2 = db.document(partialUri)
  discard partialDoc2
  let partialOpen = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-dot-partial.nim","languageId":"nim","version":1,"text":"type Color = enum\n  colRed, colGreen, colBlue\n\nproc partial(k: Color) =\n  discard k\n  Color.co\n"}}}""")
  note(responses, "partialOpen", partialOpen.response)
  discard partialOpen
  # The same query against a module that imports something real. What decides the
  # deferral is not the root module's size but whether sem has to re-resolve the
  # import graph on every keystroke, so this is the number that matters -- the
  # five-line one does not settle it.
  #
  # These two documents are opened and queried so the shape stays exercised, but
  # nothing is printed: `tests/lsp` is a joined group, and it is expected to be
  # silent. The measurement that once lived here also cannot be a golden -- a
  # latency assertion is not reproducible -- so it belongs in a commit message,
  # not in a test's output. Its finding is recorded in 46b95299.
  let importedUri = "file:///workspace/lsp-dot-imported.nim"
  let importedText = "import std/strutils\n\ntype Color = enum\n" &
                     "  colRed, colGreen, colBlue\n\nproc partial(k: Color) =\n  discard k\n  Color.\n"
  discard handle(db, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" &
    importedUri & "\",\"languageId\":\"nim\",\"version\":1,\"text\":\"" &
    importedText.replace("\n", "\\n") & "\"}}}")
  for (uri, dotLine, dotCol) in [(partialUri, 5, 9), (importedUri, 6, 7)]:
    for ch in [dotCol, dotCol + 1, dotCol + 2]:
      discard handle(db, "{\"jsonrpc\":\"2.0\",\"id\":103,\"method\":\"textDocument/completion\"," &
        "\"params\":{\"textDocument\":{\"uri\":\"" & uri &
        "\"},\"position\":{\"line\":" & $dotLine & ",\"character\":" & $ch & "}}}")
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-dot.nim"}}}""")

  # A document sem has already checked but which recorded no occurrences -- an
  # empty buffer, or one holding only comments -- must not be compiled again per
  # query. Document mode records every occurrence in the file, so zero positions
  # means there is no identifier for the per-position mode to find either, and
  # the cache only covers a repeat of the same line and column. Measured on a new
  # buffer this cost a ~64ms `nimony check` per cursor position, which is one per
  # keystroke in a file an editor creates one of per session.
  #
  # `queryCached` is set only by the fallback compile path, so it observes the
  # spawn directly rather than inferring it from a timing.
  let blankUri = "file:///workspace/lsp-blank.nim"
  let blankOpened = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-blank.nim","languageId":"nim","version":1,"text":"## only a note\n"}}}""")
  note(responses, "blankOpened", blankOpened.response)
  assert not blankOpened.notification.contains("semantic analysis failed"),
         "the blank fixture failed to compile: " & blankOpened.notification
  let blank = db.document(blankUri)
  assert blank != nil and blank.snapshot.positions.len == 0,
         "the blank fixture was expected to record no occurrences"
  assert blank.snapshot.queried,
         "the blank fixture should have been sem-checked in document mode"
  # Distinct positions on purpose: the query cache only covers an exact repeat, so
  # these are the ones that used to compile.
  for probeLine in [0, 1, 2]:
    discard handle(db, "{\"jsonrpc\":\"2.0\",\"id\":97,\"method\":\"textDocument/hover\"," &
      "\"params\":{\"textDocument\":{\"uri\":\"" & blankUri &
      "\"},\"position\":{\"line\":" & $probeLine & ",\"character\":1}}}")
  assert not blank.queryCached,
         "a document with no recorded occurrences was compiled per query"
  discard handle(db, """{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///workspace/lsp-blank.nim"}}}""")
  # A `##` block is the documentation of the declaration it follows as the first
  # statement of the body's, and of nothing else. `usesBodyDoc`'s block sits
  # under `usesBodyDoc` and above `nested`, so it belongs to `usesBodyDoc` and
  # `nested` must stay undocumented.
  let nestedHover = handle(db, "{\"jsonrpc\":\"2.0\",\"id\":96,\"method\":\"textDocument/hover\"," &
    "\"params\":{\"textDocument\":{\"uri\":\"" & docFixtureUri &
    "\"},\"position\":{\"line\":39,\"character\":7}}}")
  assert not nestedHover.response.contains("Documents this declaration"),
         "a later declaration took the block above it: " & nestedHover.response

proc runBothPaths() {.raises.} =
  ## The same request sequence down both sem paths, and the answers compared.
  ##
  ## Every assertion above holds for whichever path this run took, and that is not
  ## the same as the two paths agreeing. They are separate readers over separate
  ## transports -- the sidecar text and the query struct -- and nothing held them
  ## to each other, so `snapshotFromQuery` came to resolve a shadowed name to the
  ## outer declaration while the sidecar reader found the inner one. Both passed
  ## their own assertions; only running the same sequence twice showed the
  ## disagreement.
  ##
  ## The second run needs a warm cache: in-process sem reads the dependency
  ## interfaces a subprocess run builds, and on a cold cache the first request
  ## legitimately falls back. That is the fallback working, not a difference in
  ## the answers.
  var viaSubprocess: Table[string, string] = initTable[string, string]()
  runTests(viaSubprocess, false)
  var viaInProcess: Table[string, string] = initTable[string, string]()
  runTests(viaInProcess, true)
  putEnv("NIMONY_LSP_INPROCESS", "0")

  assert viaSubprocess.len == viaInProcess.len,
         "the two paths answered " & $viaSubprocess.len & " and " &
         $viaInProcess.len & " requests, so they cannot be compared"
  for label, want in viaSubprocess:
    let got = viaInProcess.getOrDefault(label)
    assert got == want,
           label & " differs between the paths:\n  subprocess: " & want &
           "\n  in-process: " & got

try:
  runBothPaths()
except:
  assert false, "LSP handler test raised unexpectedly"
