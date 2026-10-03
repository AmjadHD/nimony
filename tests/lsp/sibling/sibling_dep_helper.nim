proc siblingAnswer*(): int =
  ## A documented answer that lives in a sibling module.
  ##
  ## The point of the pair is the `import sibling_dep_helper` in the other
  ## file: a `./`-less sibling import resolves against the *importing* file's
  ## own directory, which the language server has to keep supplying even though
  ## it hands the root to sem as a pre-parsed `.nif` under the cache dir.
  42