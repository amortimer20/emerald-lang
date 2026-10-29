# Finding 05: round_to changes large values it should leave alone.
# Expected (9.3: precision beyond binary64's decimal range leaves a finite value unchanged
# on the fractional side): each value printed unchanged.
print(2247410860550237.2.round_to(2))   # expected 2247410860550237.2
print(3949998310996723.5.round_to(1))   # expected 3949998310996723.5
print(1e300.round_to(5))                # expected 1e+300
print(1e300.round_to(-300))             # expected 1e+300
print((-28609247935418.004).round_to(2)) # expected -28609247935418.0
