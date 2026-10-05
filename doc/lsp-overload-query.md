# Phase 2v2 — best-effort overload resolution: design note

The decision this note records is the one Phase 2v1 defers: **when an argument's
type cannot be established, does the candidate survive?**

**Answer: (b).** An argument of unknown type eliminates nothing. A candidate is
eliminated only on evidence that does not depend on the missing type — arity, or
another argument whose type *is* established and provably cannot match.

Written before implementation, as the phase requires.

## Why (b)

(b) is the only option that is *sound*. "Provably incompatible" has to mean
incompatibility that is decidable without the type we do not have. So a
candidate can only be dropped when we can point at the reason. If we ever drop a
candidate for a reason that an unfinished edit would have supplied, the editor has
guessed, and a guessed verdict is worse than none: the user sees a completion list
missing the one they wanted, with nothing indicating why.

The two rejected options:

- **(a) eliminate nothing.** Sound, but too weak to be useful. It cannot narrow
  anything on a call whose arguments are all unresolved, and post-dot completion
  is impossible under it, because the receiver is precisely the thing that has to
  be known.
- **(c) something else** — in practice, scoring candidates by how well they fit
  and ordering by score. That is a heuristic wearing a verdict's clothes. It would
  have to invent a tie-break among equally-supported candidates, and that
  tie-break is a guess with no evidence behind it.

What (b) costs is a *larger* candidate set, not a wrong one. Ordering what remains
is the editor's business; deciding membership is the compiler's, and (b) keeps
that decision to what can be proved.

## The judgement has three values, not two

`sigmatch` decides pass/fail. `typematch` (`sigmatch.nim:2627`) is where a single
formal/argument pair is settled, and it reports by recording an error. (b) needs
that pair to have three possible outcomes instead of two:

| verdict | meaning | effect on the candidate |
| --- | --- | --- |
| compatible | the established type matches | none |
| incompatible | the established type provably cannot match | eliminated |
| unknown | no usable type for this argument | none |

A candidate survives if and only if it has no `incompatible` pair. `unknown` is
absent from the elimination rule entirely — that is the whole of (b).

## The subtlety: a known argument can still be `unknown`

This is the part a naive reading of (b) gets wrong, and it is why the note exists.

An argument's own type being established is not sufficient to call the pair
`compatible` or `incompatible`. Consider

```nim
proc takes(x: int; y: T)          # T inferred from y
takes(1, someUnresolvedThing)
```

`x`'s type is known. So is `y`'s *formal*. But `T` is not yet bound, and binding
it is exactly what the unresolved argument is for. Deciding the `x`/`int` pair
looks independent and is not: the routine's instantiation depends on the argument
we cannot type.

So the rule is about **dependencies, not about the argument in front of you**:

> A pair is `incompatible` only when the incompatibility holds for *every*
> binding of the still-unknown parts. If deciding it would require a type
> variable that an unknown argument must bind, the pair is `unknown`.

For a non-generic formal against a known argument, that reduces to ordinary
compatibility. It only bites when generics are in play, which is precisely where
getting it wrong is easy and where being wrong is invisible.

## What "unknown" looks like in the tree

Measured against the recovering parser, which is the only producer of a tree for a
file mid-edit — batch `nifler2` is fail-fast and yields nothing at all.

| shape | tree | the argument is |
| --- | --- | --- |
| unterminated call `takes(h.field, unde` | `(call takes (dot h field) unde (err …) (err …))` | a bare `Ident` with no symbol |
| unresolved ident `takes(1, undeclaredName)` | `(call takes 1 undeclaredName)` | an `Ident`, and **no parse error at all** |
| bad argument `takes(1, let = 2)` | `(call takes 1 (err …))` | an `(err)` node holding the raw text |
| partial member access `h.` | `(dot h (err …) (err …))` | no name present at all |

Two consequences worth stating plainly:

- **The second row is not a recovery case.** It parses cleanly and fails only in
  sem. A design that keys off `(err …)` nodes misses it entirely, and it is
  probably the most common thing a user hits while typing.
- So "unknown" must be detected from the *argument*, not from the presence of an
  error: no resolved symbol, or no established type cursor, or a type that is
  `UntypedT`. `CallArg` already carries `orig` — *"original tree before
  semchecking, used for untyped args"* (`sigmatch.nim:18`) — which is what the
  query reads to tell the user what they actually typed.

`UntypedT` is already special-cased on the batch path (`semcall.nim:1661` sets
`skipSemCheck`), so untyped arguments are not a new case; they are an existing one
that currently short-circuits the whole check.

## Query shape

The prompt is explicit that this is a different question and not an extension of
2v1's. Concretely:

- 2v1 is a **point lookup**: "does this resolve, and to what." One symbol out, or
  none.
- 2v2 is a **range query**: "given possibly-unknown argument types, which
  overloads remain compatible." A *set* out.

So a new routine, sharing name resolution and the scope chain with 2v1's
`buildSymChoice`, and **not** calling `sigmatch`. It may share the per-pair
compatibility reasoning — see the refactoring note below — but it must not go
through sigmatch's pass/fail entry point, because that entry point's contract is
to produce a verdict and an error message, and a completion query needs the
former without the latter.

**The invariant that matters most: a query must not report diagnostics.**
`sigmatch` accumulates errors into a `Match`. A completion request that ran it
would start publishing errors the user did not write, from a file they had not
finished editing. Whatever is shared with the batch path has to be callable
without the error side effect.

## Refactoring `sigmatch` rather than duplicating it

Duplicating the compatibility rules would guarantee they drift, and the drift
would be invisible until a call that should have compiled did not. The rules
should be factored out so that:

- the batch path keeps its exact current semantics — a call that does not typecheck
  still fails, with the same message, from the same code path; and
- the new path adds the third verdict and the "every binding" rule, in new code
  that *calls* the shared rules rather than restating them.

Widening `typematch` to return three values would change what the batch path does
with a mismatch unless every existing caller is audited; keeping the batch entry
point untouched and adding a sibling is auditable in a way that changing it is not.

### What is already exposed, by name

A general promise to "factor out" is worth nothing, so concretely:

| what | where | note |
| --- | --- | --- |
| `sigmatch(m, fn, args, explicitTypeVars)` | `sigmatch.nim:2881` | the batch entry point; stays untouched |
| `typematch(m, formal, arg: Item)` | `sigmatch.nim:2627` | the per-pair decision; the natural place for a third verdict |
| `classifyMatch(m): TypeRelation` | `sigmatch.nim:2645` | already a *graded* relation, not a boolean |
| `Match.inferred` / `Match.unboundTvars` | `sigmatch.nim:64` | the binding set and the count of what is still unbound |
| `bindTypevar(m, fs, a)` | `sigmatch.nim:115` | the only mutator; decrements the count |
| `anArgIsStillUntyped(args)` | `sigmatch.nim:2871` | **already the (b) rule**, narrowly |

Two of these deserve emphasis, because they make the job smaller than a first
reading suggests.

`classifyMatch` already returns a graded `TypeRelation` (`NoMatch`, `EqualMatch`,
`GenericMatch`, …), not a boolean. The three-valued verdict is closer to the
existing shape than a two-valued one would be.

And `anArgIsStillUntyped` is, in its own words, already this design:

> "`auto` on an argument is not a type, it is 'not decided yet' […] A typevar the
> arguments left unbound is then unbound because the ARGUMENT is unfinished, not
> because the candidate is uninstantiable — so the rejection below has nothing to
> say about it."

sigmatch therefore **already tolerates partial input**, for `AutoT`. It declines to
reject a candidate whose typevars are unbound *because an argument was unfinished*
rather than uninstantiable. `unboundTvars` is already the dependency signal the
rule above is about — a count of what the arguments did not decide.

So the honest scope is not "refactor sigmatch's internals to accept partial
input". It is:

1. **widen `anArgIsStillUntyped`** from `AutoT` alone to the full unknown set — no
   resolved symbol, no established type cursor, `UntypedT`, or an `(err)` node in
   argument position; and
2. **expose the per-pair decision** so the 2v2 path can read a three-valued verdict
   instead of the whole-call boolean, without going through `sigmatch` and so
   without its error accumulation.

(1) is the one with a hidden dependency worth stating: the predicate takes
`openArray[CallArg]` and today sees only `typ`. Whether an argument came from an
`(err)` node is not visible to it. `CallArg.orig` exists but is documented as
"used for untyped args", so widening this needs that field (or a flag) to carry
the fact — which is a change to how `CallArg` is built at `semcall.nim:1621` and
`:1664`, not only to the predicate.

That is the one place where "expose a few helpers" understates the work, and it is
worth knowing before starting rather than after.

## Arity

Named as safe in (b), with one caveat that makes it easy to get wrong. "Wrong
number of arguments" is not a property of the raw argument count, because Nim has
default parameters, named arguments, and a varargs tail. The test is whether *any*
binding of parameters to arguments exists:

- surplus arguments are fine if a varargs parameter absorbs them;
- a missing argument is fine if the trailing parameters have defaults;
- named arguments bind by name, so order does not constrain them.

Eliminating on the raw count would drop legitimate candidates, which is the exact
failure mode (b) exists to avoid.

## Order of work

Not all three of the phase's criteria need the range query, and shipping them
together would put the most speculative piece first.

1. **Post-dot completion from a known receiver.** The fourth shape above shows the
   receiver is frequently fully typed while the member name is absent — `h.` with
   `h: Holder`. This is a type query on one expression, not a range query over
   arguments. It is not already built: `buildSymChoiceForDot` (`sembasics.nim:57`)
   is marked *"not used yet"* and only sweeps the scope for same-named routines,
   which is the name-based approach 2v1 already has, not the type-directed one
   this needs.

   **The honest caveat on calling this the cheap one.** It is cheap *relative to
   mid-call completion*, and it stays cheap under exactly one condition: the
   receiver's type is already established. If the receiver came from a generic
   call whose typevars are unbound, its type is genuinely unknown, and the correct
   answer is **no result** — 2v1's existing stance — not a fallback into the
   dependency machinery. So the case that would pull (b)'s dependency tracking into
   post-dot completion is the case we decline rather than attempt. What remains is
   a walk of an established type's members, which needs no overload resolution at
   all.

   That distinction is what makes the ordering safe rather than optimistic: it is
   a claim about which cases are *excluded*, not an estimate of the included ones.
2. **Signature help.** Needs the parameter lists of all candidates, filtered by
   (b). No inference, no new resolution logic; it is mostly presentation.
3. **Mid-call completion** (`foo.bar(x`). The range query itself. Ship last,
   because it is the piece whose value depends on (1) and (2) having been used.

Note that (1) does not need `anArgIsStillUntyped` widened at all, so it does not
wait on the one piece of plumbing described above. That is a further reason to put
it first: it is the only criterion with no dependency on the `CallArg` change.

## What stays out

Unchanged from 2v1, and not revisited here: completions where the receiver's type
is genuinely unknown (not merely unfinished) still return nothing, and a call
whose overload cannot be determined still returns an empty result rather than a
guess. "No result" remains a first-class answer.

## Success criteria for this phase

Scoped to what 2v1 punts on, per the prompt:

- `foo.bar(x` with `x` unresolved offers the overloads (b) leaves standing, and
  offers nothing it cannot justify.
- `h.` completes from `h`'s type even though no member name has been typed.
- Signature help mid-call lists each surviving candidate's parameters.
- **And the negative cases**, which matter as much: a file mid-edit must produce
  no diagnostics it did not have, and a batch compile of a file that does not
  typecheck must still fail exactly as before. A phase that only adds answers is
  not finished until it has been shown not to take any away.

## Open questions

Recorded rather than answered, because answering them needs code this note is
written before.

- **Widening `anArgIsStillUntyped` needs `CallArg` to carry more.** The predicate
  sees only `typ`, so it cannot tell an `AutoT` argument from one that came from an
  `(err)` node. Either `orig` starts carrying that fact, or a flag does. This
  touches argument construction at `semcall.nim:1621`/`:1664`, which is the widest
  blast radius of anything described here.
- **`unboundTvars` is a whole-call count, not a per-argument one.** (b) needs the
  dependency per pair — which argument is holding which typevar open. Deriving
  that from a single counter may mean threading per-typevar provenance through
  `bindTypevar`, or accepting a coarser approximation for generics and saying so.
  Whether the coarse version is still sound is not obvious and should be settled
  before the range query is written, not during.
- **No signature help exists yet.** `handlers.nim` has completion, hover,
  go-to-definition and diagnostics; there is no `textDocument/signatureHelp` to
  extend. It is listed as cheap above because it needs no resolution logic, not
  because the plumbing exists.