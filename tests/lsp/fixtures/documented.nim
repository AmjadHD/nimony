## Module documentation.
## Second line of it.

type
  Thing* = object
    ## The field's own documentation.
    name*: string
    # A plain hash is not documentation.
    size*: int

## A simple one-line doc.
proc simple*(): int =
  1

## First paragraph of a two-paragraph doc.
##
## Second paragraph, with `code` and a list:
##
## - one
## - two
proc twoParagraphs*(): int =
  2

##[ A block comment.
    It spans lines and keeps its shape. ]##
proc blockDoc*(): int =
  3

# an ordinary comment, not documentation
proc undocumented*(): int =
  4

proc usesBodyDoc*(x: int): int =
  ## Documents the declaration below, not this one.
  discard x
  nested*()
  5

proc nested*(): int =
  6