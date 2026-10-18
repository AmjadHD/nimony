## Module documentation.
## Second line of it.

type
  Thing* = object
    name*: string
    ## The field's own documentation.
    size*: int
    # A plain hash is not documentation.
    other*: int

proc simple*(): int =
  ## A simple one-line doc.
  1

proc twoParagraphs*(): int =
  ## First paragraph of a two-paragraph doc.
  ##
  ## Second paragraph, with `code` and a list:
  ##
  ## - one
  ## - two
  2

proc blockDoc*(): int =
  ##[ A block comment.
      It spans lines and keeps its shape. ]##
  3

# an ordinary comment, not documentation
proc undocumented*(): int =
  4

proc usesBodyDoc*(x: int): int =
  ## Documents this declaration, not the next one.
  discard x
  nested*()
  5

proc nested*(): int =
  6

proc inlineDoc*(): int = 4
  ## `inlineDoc`'s own doc: an indented block under a one-line body is still the
  ## first thing after the declaration, and `nim doc` attaches it the same way.
  ## Only a `##` sharing the NEXT declaration's line belongs to that one.
