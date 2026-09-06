# Type arguments are only meaningful where something declares a type parameter, and
# §5.3 defers declaring -- so the compiler-owned methods are the whole list.

print([1].count<Int>())
