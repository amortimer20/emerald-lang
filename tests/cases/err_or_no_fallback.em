## .or with nothing to fall back to. Being an intrinsic, it sat in no signature table and
## nothing checked its arity: this reached the runtime and read past the end of its own
## argument list, which surfaced as a .NET error rather than as this.
var n: Int? = nothing

print(n.or())
