# Section 8.1: a list is a value. Assignment and argument passing produce an
# independent list, at every level of nesting.

var original = [1, 2, 3]
var copy = original
copy.append(4)
copy[0] = 100
print(original, copy)

var rows = [[1], [2]]
var rows_copy = rows
rows_copy[0].append(9)
print(rows, rows_copy)

# A parameter cannot change (7.1), so a function returns the changed value.
func with_guest(guests: List[Int], guest: Int): List[Int] {
    var updated = guests
    updated.append(guest)
    return updated
}

var party = [1, 2]
var bigger = with_guest(party, 3)
print(party, bigger)

# A change the function makes through a module binding does not show through
# the parameter, which is its own value.
var shared = [1]
func show(items: List[Int]) {
    shared.append(2)
    print(items)
}
show(shared)
print(shared)

# Section 8.4: a loop visits the list as it was when the loop began.
var growing = [1, 2]
for item in growing {
    growing.append(item * 10)
}
print(growing)
