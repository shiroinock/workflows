# Carries the "# zizmor: ignore[...]" comments of a template over to a copy already in a repository.
#   awk -f zizmor-ignores.awk <template> <copy in the repository>
# A line of the copy that equals a template's line without its ignore comment gets the comment. Any
# other line is left as it is: a line the repository changed (a uses: pinned to a SHA, say) keeps no
# finding to ignore or is the repository's own business. Running it again changes nothing.
FNR == NR {
  if (match($0, / +# zizmor: ignore\[/)) annotated[substr($0, 1, RSTART - 1)] = $0
  next
}
{ print (($0 in annotated) ? annotated[$0] : $0) }
