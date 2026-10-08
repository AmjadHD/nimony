## Find references: the other occurrences of whatever the cursor is on.
##
## The question this answers is the reverse of every other request here. Hover and
## go-to-definition ask "what is this one occurrence"; references asks about the
## occurrences the cursor is *not* on, so it is answered from the whole
## document-mode snapshot rather than from one position of it.
##
## What the rules have to get right, and why each case is here:
##
## * an overload set is not one symbol. `overload(1)` and `overload("s")` are two
##   occurrences of one name that resolved to two different declarations, and
##   reporting them as two references to each other is the one wrong answer a
##   reference query can give. So the two are pinned apart here.
## * a declaration is an occurrence. sem records the declaration's own name as a
##   resolved occurrence, which is what makes `includeDeclaration: false` possible
##   rather than something the handler has to reconstruct.
## * a name that resolved to nothing has no identity. sem records `b.field` with an
##   empty source file, so every member would carry the same key and find-references
##   on a field would return every member in the file. It returns none.
##
## The fixture is an array of lines rather than a block of text so the line numbers
## in the expectations are the ones a reader counts. Writing the text as a raw
## string would put them one off, because a raw string drops the newline right
## after its opening quotes -- which is exactly the kind of off-by-one that gets
## corrected by reading the output until it agrees.
##
## Run once per sem path. `referencesAt` reads `doc.snapshot`, and the two paths
## build that through different readers -- the same pair `boundary.nim` holds to
## agreeing -- so exercising one and not the other would only prove half of it.

import std / [assertions, os, strutils, syncio, envvars]

import ../../src/lsp/[database, handlers]

const lines = [
  "proc target() = discard",                # 0
  "",                                       # 1
  "proc caller() =",                        # 2
  "  let inner = 1",                       # 3
  "  discard inner",                       # 4
  "  discard inner",                       # 5
  "",                                       # 6
  "proc overload(x: int) = discard",        # 7
  "proc overload(x: string) = discard",     # 8
  "",                                       # 9
  "proc picks() =",                        # 10
  "  overload(1)",                         # 11
  "  overload(\"s\")",                     # 12
  "",                                       # 13
  "type Box = object",                      # 14
  "  field*: int",                         # 15
  "",                                       # 16
  "proc member(b: Box) =",                 # 17
  "  discard b.field",                     # 18
  "",                                       # 19
  "proc wide(x: int) = discard",           # 20
  "proc wide(x: string) = discard",        # 21
  "",                                       # 22
  "proc undecided(y) =",                   # 23
  "  wide(y)",                             # 24
  "",                                       # 25
  "proc settled() =",                      # 26
  "  wide(1)"                              # 27
]

let source = lines.join("\n") & "\n"

proc escaped(s: string): string =
  ## The fixture as a JSON string body.
  ##
  ## Hand-written rather than taken from `std/json`: the handler has its own
  ## `quoteJson`, and a request built with the *stdlib's* escaping would be the one
  ## request in this test not exercising the round trip the editor actually makes.
  ##
  ## It has to exist at all. A JSON string cannot contain a raw newline, and the
  ## fixture is 19 lines long -- sending it unescaped made `parseJson` fail, `handle`
  ## return an empty notification, and the first assertion fail with an empty message
  ## rather than pointing at the request. `overload("s")` needs the quotes escaped for
  ## the same reason.
  result = ""
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

proc openRequest(uri, text: string): string =
  ## A `didOpen` carrying `text`.
  ##
  ## The literal quotes and braces need no escaping: these are raw strings, so
  ## writing `\"` here would put a BACKSLASH in the JSON -- which `parseJson` rejects,
  ## and `handle` answers by returning an empty result rather than an error. That is
  ## what made the first run of this test fail on an assertion with an empty message
  ## instead of on the request.
  ("""{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"""" &
    uri & """","version":1,"text":"""" & text & """"}}""")

proc closeRequest(uri: string): string =
  ("""{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"""" &
    uri & """"}}}""")

proc request(verb, uri: string; line, character: int;
             includeDeclaration: bool): string =
  # `""""` and not `"""` at each join where a quote has to survive: four quotes is a
  # raw string ENDING with a quote, three is one ending just before the next
  # character. Written the other way this emitted
  # `"method":textDocument/references,"params"` -- the quotes around the method
  # vanished, `parseJson` still accepted the result, and the handler answered
  # "Method not found" for a method it implements. A wrong-but-parseable request is
  # worse than a malformed one: it fails as a missing feature rather than as a bug,
  # and `handle` returning nothing rather than an error is what hid it for a while.
  #
  # One parenthesised expression rather than a chain of `&` across lines: this
  # stdlib parses the trailing `+` form as arithmetic.
  ("""{"jsonrpc":"2.0","id":1,"method":"""" & verb & """","params":{""" &
    """"textDocument":{"uri":"""" & uri & """"},""" &
    """"position":{"line":""" & $line & ""","character":""" & $character &
    """},"context":{"includeDeclaration":""" & $includeDeclaration & """}}}""")

proc positions(response: string): seq[string] {.raises.} =
  ## The `line:character` of every location in a `Location[]`, as reported.
  ##
  ## Not a substring search: the assertion that matters most here is that a line is
  ## *absent*, and `"line":3` cannot be shown absent inside a response that also
  ## contains `"line":13`.
  ##
  ## `find` with an explicit start offset rather than slicing at a hardcoded length:
  ## the first version counted the marker's characters by eye and was off by two,
  ## which surfaced as `"character":6}` where a line number belonged. A marker
  ## searched for by `find` cannot drift out of step with itself.
  result = @[]
  # The whole `"line":N,"character":M` run as one marker, so neither number has to be
  # located separately. Splitting it in two and searching for the second colon found
  # the one inside `"character"` instead, because a JSON key is `":"` too.
  const marker = "\"start\":{\"line\":"
  const tail = ",\"character\":"
  var i = 0
  while true:
    let at = response.find(marker, i)
    if at < 0: break
    let comma = response.find(',', at + marker.len)
    assert comma > 0, "malformed start position in " & response
    let charAt = response.find(tail, comma)
    assert charAt == comma, "malformed start position in " & response
    let stop = response.find('}', charAt + tail.len)
    assert stop > 0, "malformed start position in " & response
    result.add response[at + marker.len ..< comma] & ":" &
              response[comma + tail.len ..< stop]
    i = at + marker.len

proc assertBalanced(response, label: string) =
  ## Every response must be balanced JSON. A substring assertion cannot see this:
  ## `{"result":[]}` *contains* `"result":[]` while being one brace short, and that
  ## is exactly what a handler returned once.
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
  assert depth == 0, label & " is " & $(-depth) & " brace(s) out of balance: " &
                    response

proc check(db: var Database; uri: string; label: string; line,
             character: int; includeDeclaration: bool;
             want: seq[string]) {.raises.} =
  ## Flat and threaded rather than a nested proc closing over `db` and `uri`, which
  ## this stdlib would require `{.closure.}` to accept -- `tserver.nim` hit the same
  ## wall and threaded its table through a proc for the same reason.
  let response = handle(db, request("textDocument/references", uri, line,
                                    character, includeDeclaration)).response
  assertBalanced(response, label)
  let got = positions(response)
  assert got == want,
         label & ": got [" & got.join(", ") & "], expected [" & want.join(", ") &
         "]\n" & response

proc runTests(inProcess: bool) {.raises.} =
  putEnv("NIMONY_LSP_INPROCESS", if inProcess: "1" else: "0")
  var db = initDatabase(getCurrentDir())
  if inProcess:
    # In-process sem gates on a dependency closure it cannot build, so the
    # subprocess path has to have run first -- against the same cache, which is why
    # the subprocess pass is not skipped in the loop below. `tserver.nim` depends
    # on the same ordering for the same reason.
    let warmUri = "file:///workspace/references-warm.nim"
    discard handle(db, openRequest(warmUri, escaped("let warm = 1\ndiscard warm\n")))
    discard handle(db, closeRequest(warmUri))

  let uri = "file:///workspace/references.nim"
  let openBody = openRequest(uri, escaped(source))
  let opened = handle(db, openBody)
  # A document sem could not check answers nothing, so assert it checked this one
  # rather than letting every expectation below pass against an empty snapshot.
  assert opened.notification.contains("publishDiagnostics"),
         "empty notification; body was " & openBody

  check(db, uri, "a local's declaration and both uses", 3, 8, true,
        @["3:6", "4:10", "5:10"])

  # The declaration is dropped by `includeDeclaration: false`, and only it: sem
  # records a declaration's own name as a resolved occurrence, which is what makes
  # this a filter over the same answer rather than a second query.
  check(db, uri, "without the declaration", 3, 8, false,
        @["4:10", "5:10"])

  # The two overloads are the point. A cursor on either reports that overload's
  # declaration and its own call, and NOT the other one. This is where the first
  # version of `spansOf` failed: it unioned the overload set with the resolution, so
  # both call sites came out as {int, string}, matched each other, and each reported
  # the other's call as a reference.
  check(db, uri, "the int overload", 11, 4, true, @["7:5", "11:2"])
  check(db, uri, "the string overload", 12, 4, true, @["8:5", "12:2"])

  # And the same pair with the declaration excluded, which here leaves the call alone
  # -- the other overload's declaration is not a substitute for it.
  check(db, uri, "the int overload, without the declaration", 11, 4, false,
        @["11:2"])

  check(db, uri, "a declaration nothing uses", 0, 7, true,
        @["0:5"])

  # Nothing resolved, so there is no identity to match on. An empty array is the
  # truth rather than a failure, and the editor shows it as "no results".
  check(db, uri, "a blank line", 13, 0, true, @[])

  # The member name resolved to nothing, so every member in the file would share one
  # key if an unresolved row had one. It returns none -- which is honest, and is the
  # answer a field would get today.
  check(db, uri, "a member name", 18, 12, true, @[])

  # A call sem could not decide records only the SET it weighed -- `wide(y)` where
  # `y`'s type is unknown leaves both overloads standing. It is not a reference to
  # either one, and this is the case that needs the resolution sets to be EQUAL
  # rather than merely overlapping: the settled call below resolves to the int
  # overload, so an intersection rule would report `wide(y)` as a reference to it.
  # That was verified by mutation -- dropping the length check in `sameKeys` passed
  # the suite until this case existed.
  check(db, uri, "a settled call", 27, 4, true, @["20:5", "27:2"])

  # And an undecided call is a reference to itself only: its two candidates' own
  # declarations each resolve to ONE of them, so neither is the set.
  check(db, uri, "an undecided call", 24, 4, true, @["24:2"])

  discard handle(db, closeRequest(uri))

try:
  # Subprocess first: it is the pass that builds the dependency closure the
  # in-process pass then gates on.
  runTests(false)
  runTests(true)
  echo "references: ok"
except:
  assert false, "references raised unexpectedly"