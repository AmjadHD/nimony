## One sem run, two answers: the struct `semcheckInProcess` returns and the sidecar
## the same run also wrote.
##
## The sidecar is still written because `writeIdeQuery` runs inside `semcheckCore`,
## so one call produces both and they can be compared field by field. Comparing
## across one run rather than two is the point: two runs can differ for reasons
## that have nothing to do with the change under test -- a rebuild, a stale cache,
## an order that is not deterministic -- and a test that tolerates that can pass
## while the boundary is broken.
##
## The failure guarded against is narrow and real. A field that round-trips
## through string formatting one way but copies as a struct the other agrees with
## every behavioural comparison, because both sides then match on everything
## *except* the one field nothing reads back.
##
## The comparison is against `parseIdeSnapshot`, the reader the LSP itself uses,
## not a second implementation of the format written here. A local reimplementation
## would test the test: had `escapeTsv` and `unescapeTsv` drifted apart, matching
## them against each other would pass while the sidecar had become unreadable to
## the editor. Comparing producer against production reader can only fail when one
## of them is wrong.
##
## Both modes are exercised, because `writeIdeQuery` writes disjoint row sets in
## each: document mode emits `position`/`candidate`/`import`, cursor mode emits
## `visible`/`candidate`/`signature`/`dotmember`. A single-mode test would leave
## half the sidecar uncompared.

import std / [assertions, os, strutils, syncio]
import ../../src/nimony / [semmain, semdata, nifconfig, semos]
import ../../src/lsp / database
import ../../src/lib / nifpools

proc parseSource(text, path: string): (int, int) =
  ## The first position a document-mode run records, so the test can point the
  ## cursor at a real identifier rather than at a guess. Returns (line, column),
  ## one-based, as the sidecar numbers them. (-1, -1) when there is none, which
  ## the caller turns into a failure rather than a compile at a bogus position.
  result = (-1, -1)
  let rows = text.splitLines()
  for i in 0 ..< rows.len:
    let row = rows[i]
    var j = 0
    while j < row.len and not isIdentStart(row[j]): inc j
    if j < row.len:
      return (i + 1, j + 1)

proc isIdentStart(c: char): bool =
  ## Deliberately the same test `parseSource` needs and no more: this stdlib has
  ## no `isAlphaNumeric` on `char`, and a `while` with an inline predicate reads
  ## worse than a named one.
  c in {'a'..'z', 'A'..'Z', '_'} or ord(c) >= 0x80

proc namesOf(syms: seq[IdeSymbol]): seq[string] =
  ## The identifier text the sidecar's `symBasename` column would carry.
  result = @[]
  for sym in syms:
    result.add pool.symBasename(sym.id)

proc sidecarAt(db: Database, doc: Document): string =
  ## `semcheckInProcess` writes the sidecar under the module's own suffix, which
  ## is what the LSP reads back. Derived rather than hardcoded so a change to the
  ## naming shows up as a missing file, which the assert below names.
  result = db.root / "nimcache" / (doc.moduleName & ".ide.tsv")

proc runBothModes(label, text: string) {.raises.} =
  ## One document, checked twice: once in document mode, once with the cursor on
  ## an identifier. Returns nothing; every disagreement is an assertion.
  var db = initDatabase(getCurrentDir())
  let path = db.cacheDir / (label & ".nim")
  writeFile(path, text)
  let doc = db.updateDocument("file://" & path, path, 1, text)
  # Sem the copy inside the cache, for the reason spelled out below.
  let parsed = db.root / "nimcache" / (doc.moduleName & ".p.nif")
  try:
    writeFile(parsed, readFile(doc.parsedFile))
    writeFile(db.root / "nimcache" / (doc.moduleName & ".p.deps.nif"),
              readFile(db.cacheDir / (doc.moduleName & ".p.deps.nif")))
  except:
    discard
  let sidecar = sidecarAt(db, doc)

  # Document mode: every occurrence, the import table, the errors.
  var config = initNifConfig(db.root)
  # The repo's own nimcache, and the parsed file copied INTO it. Both halves are
  # load-bearing and neither is what the names suggest:
  #
  # `semcheckInProcess` sems the one module it is handed and reads every import's
  # interface out of `<dir>/<suffix>.s.nif` -- but nothing here has *built*
  # those. That is `deps.nim`'s job, and it runs in `nifmake` ahead of sem;
  # in-process skips it, so a cold cache dies at the first import with `vfs:
  # open failed: <stdlib suffix>.s.nif`. A constraint on this entry point, and
  # it belongs in the LSP's design: build the dependency closure once before the
  # first query, or keep pointing at a cache that already has it.
  #
  # The directory is `prog.main.dir` -- where the *parsed file* lives -- not
  # `config.nifcachePath`. `suffixToNif` builds import paths from the former, so
  # a parsed file in a subdirectory looks for stdlib interfaces beside itself
  # and finds none, whatever nifcachePath says. Copying the parsed file in is
  # what the subprocess path does implicitly by passing the parsed file from
  # inside the cache dir.
  config.nifcachePath = db.root / "nimcache"
  # The search paths decide every module suffix, and a suffix computed without
  # them names a `.s.nif` that was never written -- `vfs: open failed:
  # <suffix>.s.nif`, on a file that is not missing for any reason a reader could
  # see. `semcheck` does this itself; an in-process caller has to ask.
  config.setupPaths()
  # `setupPaths` fills these from `nimonyDir()`, which resolves the stdlib
  # relative to the *executable's* parent directory. Under `hastur` this test
  # binary lives in `nimcache/c/<hash>/`, so that points at a tree with no
  # `lib/` in it and every stdlib import resolves to nothing. A subprocess never
  # notices, because it re-executes `bin/nimony`. Overwritten here so the paths
  # come from the repository this file lives in rather than from wherever the
  # binary happens to sit -- again a constraint on in-process sem, and one the
  # language server has to satisfy for itself.
  config.paths = @[db.root / "lib", db.root / "src" / "lib", db.root]
  # `semcheckCore` imports `std/system` through `stdlibFile`, which resolves
  # against the *executable's* parent directory. `hastur` puts this test in
  # `nimcache/c/<hash>/`, so that names a tree with no `lib/` in it and the
  # import dies on a missing interface -- a `.s.nif` reported absent that was
  # never written, because the directory it would go in does not exist. A
  # subprocess cannot hit this, since it re-executes `bin/nimony`. An embedding
  # host has to say where the tree is; that is what this is for.
  setProjectRoot(db.root)
  config.toTrack = TrackPosition(mode: TrackVisible, line: 0, col: 0,
                                filename: path)
  let docRun = semcheckInProcess(@[parsed], @[db.cacheDir / "out.s.nif"],
                                config, {}, "", "", false)
  assert docRun.documentMode, label & ": document mode was requested and did not happen"
  assert os.fileExists(sidecar),
         label & ": no sidecar, so there is nothing to compare"

  let docSnap = parseIdeSnapshot(doc, readFile(sidecar), -1, -1)
  assert docRun.matched == docSnap.matched,
         label & ": matched " & $docRun.matched & " vs " & $docSnap.matched
  # The transports have to agree on the MODE, not just on what the mode found.
  # `completionJson` branches on `documentMode`, so a reader that reported `false`
  # for a document mode run did not lose an answer -- it answered a different
  # question. And it could not be caught by any of the length and element compares
  # below: they all say "the same occurrences arrived", which was true while the
  # flag beside them said the opposite.
  assert docRun.documentMode == docSnap.documentMode,
         label & ": document mode " & $docRun.documentMode & " in the struct, " &
         $docSnap.documentMode & " from the sidecar"

  assert docRun.positions.len == docSnap.positions.len,
         label & ": " & $docRun.positions.len & " occurrences in the struct, " &
         $docSnap.positions.len & " in the sidecar"
  for i in 0 ..< docRun.positions.len:
    let got = docRun.positions[i]
    let want = docSnap.positions[i]
    assert got.info.line.uint32.int == want.line,
           label & ": occurrence " & $i & " line " &
           $got.info.line.uint32.int & " vs " & $want.line
    assert got.info.col.uint32.int == want.column,
           label & ": occurrence " & $i & " column " &
           $got.info.col.uint32.int & " vs " & $want.column
    # The name survives escaping, so this is where a diverging
    # escape/unescape pair shows up -- as a name that is wrong rather than
    # as a parse error nobody notices.
    assert pool.strings[got.name] == want.name,
           label & ": occurrence " & $i & " name " & pool.strings[got.name] &
           " vs " & want.name
    # Element-wise, not `==` on the sequences: `SemanticSymbol` has no `==`,
    # so a sequence compare of them is a type error rather than an answer, and
    # the obvious spelling of this check does not compile.
    assert namesOf(got.candidates).len == want.symbols.len,
           label & ": occurrence " & $i & " has " &
           $namesOf(got.candidates).len & " candidates in the struct, " &
           $want.symbols.len & " in the sidecar"
    for j in 0 ..< namesOf(got.candidates).len:
      assert namesOf(got.candidates)[j] == want.symbols[j].name,
             label & ": occurrence " & $i & " candidate " & $j & " " &
             namesOf(got.candidates)[j] & " vs " & want.symbols[j].name

  assert docRun.imports.len == docSnap.imports.len,
         label & ": " & $docRun.imports.len & " imports in the struct, " &
         $docSnap.imports.len & " in the sidecar"
  for i in 0 ..< docRun.imports.len:
    assert pool.symBasename(docRun.imports[i].id) == docSnap.imports[i].name,
           label & ": import " & $i & " " &
           pool.symBasename(docRun.imports[i].id) & " vs " & docSnap.imports[i].name

  # Cursor mode: the scope chain, the resolution, a dot's members, and the
  # overloads of the call the cursor sits in.
  let (line, col) = parseSource(text, path)
  assert line > 0, label & ": no identifier to put the cursor on"
  var cursorConfig = initNifConfig(db.root)
  cursorConfig.nifcachePath = db.root / "nimcache"
  cursorConfig.setupPaths()
  cursorConfig.paths = config.paths
  cursorConfig.toTrack = TrackPosition(mode: TrackVisible, line: line.int32,
                                       col: col.int32, filename: path)
  let cursorRun = semcheckInProcess(@[parsed],
                                    @[db.cacheDir / "out.s.nif"],
                                    cursorConfig, {}, "", "", false)
  assert not cursorRun.documentMode,
         label & ": a real cursor position was asked for and document mode ran anyway"
  let cursorSnap = parseIdeSnapshot(doc, readFile(sidecar), line - 1, col - 1)

  assert cursorRun.matched == cursorSnap.matched,
         label & ": cursor matched " & $cursorRun.matched & " vs " &
         $cursorSnap.matched
  # And the other direction, which is the one a reader that defaulted the field
  # would pass: `false` is the initial value, so a flag nobody writes reads as
  # cursor mode forever. Only a cursor-mode fixture can tell the two apart.
  assert cursorRun.documentMode == cursorSnap.documentMode,
         label & ": cursor document mode " & $cursorRun.documentMode &
         " in the struct, " & $cursorSnap.documentMode & " from the sidecar"
  # `visible` is the scope chain and the reader filters it to local symbols, so
  # the struct's list is the superset: every symbol the sidecar kept must be in
  # the struct with the same name.
  for want in cursorSnap.visible:
    assert namesOf(cursorRun.visible).contains(want.name),
           label & ": the sidecar kept visible symbol " & want.name &
           " which is not in the struct"
  for want in cursorSnap.candidates:
    assert namesOf(cursorRun.candidates).contains(want.name),
           label & ": the sidecar kept candidate " & want.name &
           " which is not in the struct"
  assert cursorRun.dotMembers.len == cursorSnap.dotMembers.len,
         label & ": " & $cursorRun.dotMembers.len & " dot members in the struct, " &
         $cursorSnap.dotMembers.len & " in the sidecar"
  for i in 0 ..< cursorRun.dotMembers.len:
    assert namesOf(cursorRun.dotMembers)[i] == cursorSnap.dotMembers[i].name,
           label & ": dot member " & $i & " " & namesOf(cursorRun.dotMembers)[i] &
           " vs " & cursorSnap.dotMembers[i].name
  assert cursorRun.signatures.len == cursorSnap.signatures.len,
         label & ": " & $cursorRun.signatures.len & " signatures in the struct, " &
         $cursorSnap.signatures.len & " in the sidecar"
  for i in 0 ..< cursorRun.signatures.len:
    assert pool.symBasename(cursorRun.signatures[i].sym) ==
           cursorSnap.signatures[i].name,
           label & ": signature " & $i & " " &
           pool.symBasename(cursorRun.signatures[i].sym) & " vs " &
           cursorSnap.signatures[i].name
    # `params` is the one field that is generated as text rather than read off
    # a symbol, so it is the one a struct copy could plausibly drop or reshape.
    assert cursorRun.signatures[i].params == cursorSnap.signatures[i].params,
           label & ": signature " & $i & " params " &
           cursorRun.signatures[i].params & " vs " & cursorSnap.signatures[i].params


proc runTests() {.raises.} =
  # Under `hastur` the test binary lands in `nimcache/`, not `bin/`, so
  # `nimonyDir()` -- which resolves the stdlib from the *executable's* parent --
  # points at the wrong tree and the first import dies on a missing interface.
  # The subprocess path never notices because it re-executes `bin/nimony`. An
  # in-process caller must be told where the project is; that is a real
  # constraint on this entry point, not a quirk of the test.
  runBothModes("boundary", """
import std/strutils

type Color = enum
  colRed, colGreen

type Obj = object
  pub*: int
  priv: int

proc pick(a: int): string = "i"
proc pick(a: string): string = "s"
proc pick(a: int, b: float): string = "if"

proc use(o: Obj, s: string) =
  discard pick(s)
  discard o.pub
  discard Color.colRed
  discard s.replicate(1)
""")
  echo "boundary: ok"
# No bare `try`/`except` at the end, deliberately: `raiseAssert` in `std/assertions`
# echoes the message and `quit`s rather than raising, so wrapping the call would
# not catch an assertion failure -- it would only swallow something that is not
# an assertion, and hide the exit code that distinguishes the two. Every assertion
# in this file carries a message naming the field, the occurrence and both sides,
# which is what makes a failure diagnosable from the report alone.
proc main() {.raises.} =
  runTests()

try:
  main()
except:
  assert false, "boundary: the run raised something that is not an assertion"
