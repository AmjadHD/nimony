## Nimony's stdio JSON-RPC language server.

{.feature: "lenientnils".}
{.feature: "assumeSync".}  # one global request queue, every access under its lock

import std / [streams, strutils, parseutils, os, syncio, locks, rawthreads]
import database, handlers

when defined(android):
  proc pthreadSetAffinityStub(thread: culong; setsize: csize_t;
                              mask: pointer): cint {.
    exportc: "pthread_setaffinity_np", cdecl.} =
    ## `std/rawthreads` calls this only for a pinned CPU, but its C declaration
    ## makes the linker demand the symbol even when the server never pins a
    ## thread. bionic omits the glibc extension, so provide the no-op it would
    ## otherwise never reach.
    discard thread
    discard setsize
    discard mask
    result = 0

const
  ChangeQuietMs = 50
    ## How long the input must be idle after a change before its check runs. A
    ## burst of keystrokes becomes one check; a single edit waits this long.

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

type
  RequestQueue = object
    lock: Lock
    cond: Cond
    items: seq[string]
    closed: bool

var requests: RequestQueue
var readerThread: RawThread
  ## `RawThread.create` stores `addr(thread)` and the reader keeps running after
  ## setup returns, so the wrapper has to outlive `startReader`.

proc enqueue(request: string) {.sync.} =
  acquire requests.lock
  requests.items.add request
  signal requests.cond
  release requests.lock

proc closeRequests() {.sync.} =
  acquire requests.lock
  requests.closed = true
  signal requests.cond
  release requests.lock

proc takeRequest(request: var string): bool {.sync.} =
  ## Block until a request is available or the reader saw end of input. The
  ## condition variable keeps an idle server asleep rather than polling stdin.
  result = false
  acquire requests.lock
  while requests.items.len == 0 and not requests.closed:
    wait(requests.cond, requests.lock)
  if requests.items.len > 0:
    request = requests.items[0]
    requests.items.delete(0)
    result = true
  release requests.lock

proc queueEmpty(): bool {.sync.} =
  acquire requests.lock
  result = requests.items.len == 0
  release requests.lock

proc readRequests(arg: pointer) {.nimcall.} =
  ## Reading stdin on its own thread is what lets the main loop debounce an
  ## edit instead of blocking in `receive`: messages keep arriving in `requests`
  ## while the main thread waits for the stream to go quiet. Only the main
  ## thread writes stdout, so the protocol transport stays single-writer.
  discard arg
  let input = newFileStream(stdin)
  while true:
    var request = ""
    try:
      request = receive(input)
    except:
      break
    if request.len == 0: break
    enqueue(request)
  closeRequests()

proc startReader() {.raises.} =
  ## `std/rawthreads` carries the runtime setup a bare `pthread_create` does
  ## not: without it, the first allocation on the reader side faults. The
  ## Android affinity stub above is what lets it link there.
  create(readerThread, readRequests, nil)

proc sendAll(output: Stream; notifications: seq[string]) {.raises.} =
  for notification in notifications:
    send(output, notification)

proc main() {.raises.} =
  initLock(requests.lock)
  initCond(requests.cond)
  startReader()
  let output = newFileStream(stdout)
  var db = initDatabase(getCurrentDir())
  var running = true
  while running:
    var request = ""
    if not takeRequest(request): break
    let requestName = requestMethod(request)
    # A change is deferred; every other request must see the check for the text
    # it names. This is also the "join the in-flight work" rule for a query:
    # `flushDiagnostics` runs the pending check now, and the quiet timer below
    # then finds nothing left to do.
    if requestName != "textDocument/didChange":
      sendAll(output, flushDiagnostics(db))
    let handled = handle(db, request, deferChanges = true)
    if handled.notification.len > 0: send(output, handled.notification)
    if handled.response.len > 0: send(output, handled.response)
    if handled.stop:
      running = false
    elif requestName == "textDocument/didChange":
      # If another message is already queued, this was not the last keystroke:
      # handle it first. Otherwise wait one quiet period; a single check follows
      # only if no request arrived while waiting.
      var quiet = false
      if queueEmpty():
        sleep(ChangeQuietMs)
        quiet = queueEmpty()
      if quiet:
        sendAll(output, flushDiagnostics(db))

try:
  main()
except:
  stderr.writeLine "nimony-lsp: protocol or I/O failure"
