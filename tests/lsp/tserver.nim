import std / [assertions, os, strutils]
import ../../src/lsp/[database, handlers]

proc runTests() {.raises.} =
  var db = initDatabase(getCurrentDir())
  let uri = "file:///workspace/lsp-test.nim"
  let opened = handle(db, """{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim","version":1,"text":"let broken = (1\nlet global = 1\nproc f() =\n  let global = 2\n  let local = global\n  local\n  global.\n  \n"}}}""")
  assert opened.notification.contains("publishDiagnostics")
  assert opened.notification.contains("expected")

  let definition = handle(db, """{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":5,"character":3}}}""")
  assert definition.response.contains("\"line\":4")
  assert definition.response.contains("\"character\":6")

  let shadowed = handle(db, """{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":4,"character":16}}}""")
  assert shadowed.response.contains("\"line\":3")
  assert shadowed.response.contains("\"character\":6")

  let hover = handle(db, """{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":5,"character":3}}}""")
  assert hover.response.contains("let local")

  let postDot = handle(db, """{"jsonrpc":"2.0","id":4,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":6,"character":9}}}""")
  assert postDot.response.contains("\"items\":[]")

  let completion = handle(db, """{"jsonrpc":"2.0","id":5,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///workspace/lsp-test.nim"},"position":{"line":7,"character":2}}}""")
  assert completion.response.contains("\"label\":\"local\"")
  assert completion.response.contains("\"label\":\"global\"")

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
