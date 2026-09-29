## Nimony's stdio JSON-RPC language server.

import std / [streams, strutils, parseutils, os, syncio]
import database, handlers

proc send(stream: Stream; message: string) {.raises.} =
  stream.write("Content-Length: " & $message.len & "\r\n\r\n")
  stream.write(message)
  stream.flush()

proc receive(stream: Stream): string {.raises.} =
  var length = -1
  while not stream.atEnd:
    let line = stream.readLine()
    if line.len == 0: break
    if line.startsWith("Content-Length:"):
      length = parseInt(line.substr("Content-Length:".len).strip)
  if length < 0 or stream.atEnd: return ""
  result = stream.readStr(length)
  if result.len != length: result = ""

proc main() {.raises.} =
  let input = newFileStream(stdin)
  let output = newFileStream(stdout)
  var db = initDatabase(getCurrentDir())
  var running = true
  while running and not input.atEnd:
    let request = receive(input)
    if request.len == 0: break
    let handled = handle(db, request)
    if handled.notification.len > 0: send(output, handled.notification)
    if handled.response.len > 0: send(output, handled.response)
    if handled.stop: running = false

try:
  main()
except:
  stderr.writeLine "nimony-lsp: protocol or I/O failure"
