## A passing assertion says nothing. That is the whole contract.
func clamp(value: Int, low: Int, high: Int): Int {
    return if value < low then low else if value > high then high else value
}

assert clamp(5, 0, 10) == 5
assert clamp(15, 0, 10) == 10
assert clamp(-5, 0, 10) == 0
assert [1, 2].count() == 2
assert "abc".upper() == "ABC"
assert not [1].empty?()
assert 3 < 4

print("all quiet")
