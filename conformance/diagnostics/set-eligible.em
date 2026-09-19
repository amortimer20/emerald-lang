# Section 8.2's set element eligibility, checked once where the set type is
# built: a written `Set[T]` and `.to_set()`.
class Holder {
    var n: Int = 0
}

const pointers: Set[Holder] = []
const from_list = [Holder()].to_set()
