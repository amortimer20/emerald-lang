# Section 14.1: naming a type through `using` does not set up its type-level fields;
# section 14.2: `using` applies to the whole file wherever it appears, and is file-local.
print("start")
const none: Circle? = nothing
print(Circle.made)
print(Tools.describe())

using Shapes
