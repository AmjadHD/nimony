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
  ## Not a doc comment for `inlineDoc`: it follows the body, and only a block
  ## that is the first statement of a body documents the declaration.
