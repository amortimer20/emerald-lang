# Section 9.4: the historical spellings stay rejected, and the checker redirects
# `slice` and `has_key?` to Emerald's name, but not these. Each gets a generic message.
const text = "hello"
print(text.pad_left(8), text.pad_right(8))
const left: Set[Int] = [1]
print(left.intersect([1]))
# Run separately (name resolution stops first): `read_line()` and `Kernel.print("hi")`
# report only "is not defined".
