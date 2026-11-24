# Carries the "# zizmor: ignore[...]" comments of a template over to a copy already in a repository.
#   awk -f zizmor-ignores.awk <template> <copy in the repository>
# Prints the copy, with the comments added; exits 0 when it added any, 1 when the copy is unchanged.
# Only a copy of the template is touched: one that calls the same shared workflow (the template's
# "uses: shiroinock/workflows/...@" line, at any ref). A claude.yml of another origin keeps its
# findings, since the reasons in the comments would not hold for it. In a copy, a line that equals a
# template's line without its ignore comment gets the comment; any other line, such as one the
# repository changed, is left as it is. Running it again changes nothing.
FNR == NR {
  if (match($0, / +# zizmor: ignore\[/)) annotated[substr($0, 1, RSTART - 1)] = $0
  if (match($0, /^ *uses: shiroinock\/workflows\/[^@]+@/)) origin = substr($0, RSTART, RLENGTH)
  next
}
{
  line[++n] = $0
  if (origin != "" && index($0, origin) == 1) copy = 1
}
END {
  for (i = 1; i <= n; i++) {
    if (copy && (line[i] in annotated)) {
      line[i] = annotated[line[i]]
      changed = 1
    }
    print line[i]
  }
  exit changed ? 0 : 1
}
