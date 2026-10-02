import std / [assertions, os, strutils]
import ../../src/lsp/[database, handlers]

proc runTests() {.raises.} =
  var db = initDatabase(getCurrentDir())
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
