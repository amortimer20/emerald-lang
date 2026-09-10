# == follows IEEE, so a NaN is equal to nothing at all, itself included.

var nan = Math.sqrt(-1.0)
var big = 1.0e308 * 10.0

print(nan.nan?())
print(big.infinite?())
print(2.5.nan?())

print("nan == nan: #{nan == nan}")
print("nan != nan: #{nan != nan}")
print("nan < 1.0:  #{nan < 1.0}")
print("nan > 1.0:  #{nan > 1.0}")
print("nan <= nan: #{nan <= nan}")

# sort keeps a total order, exactly as C# does -- an operator answering "no" to every
# question is not something a sort can be built on.
print([3.0, nan, 1.0].sort())

# The one place membership and == disagree, and the same place C# puts it: a hash
# table cannot hold a value that is not equal to itself.
print([nan, nan].to_set().count())
