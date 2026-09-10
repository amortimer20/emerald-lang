## Escaping an interpolation. Every string interpolates, so there has to be a way to
## write #{ } as text — a code generator, a tutorial, or any program printing Emerald.
var n = 5

print("value:            #{n}")
print("literal:          \#{n}")
print("escaped slash:    \\ done")
print("slash then value: \\#{n}")
print("hash alone:       \# and # and #fff")
print("dollar is free:   ${HOME} and ${x}")
