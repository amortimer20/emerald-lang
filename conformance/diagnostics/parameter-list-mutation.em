# Section 7.1: a list parameter is the function's own copy, so a change to it
# would be lost when the function returns. It is rejected rather than silently
# discarded.

func add_guest(guests: List[Int], guest: Int) {
    guests.append(guest)
}
