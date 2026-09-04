## A '?' in a name is never followed by a dot — that is what makes ?. unambiguous in a
## language whose predicates end in '?'. The cost lands here, so the diagnostic has to
## name the rule rather than report the lookup it caused.
var n = 4
print(n.even?.to_string())
