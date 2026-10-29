# Section 14.2: `using` is file-local, so the `using` here does not shorten names in
# tools/describe.em.
using Shapes

print(Circle(1))
print(Tools.describe())
