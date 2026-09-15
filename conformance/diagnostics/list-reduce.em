print([1, 2].reduce(0))
print([1, 2].reduce(0) { total => total })
print([1, 2].reduce(0) { total, number => "#{number}" })
