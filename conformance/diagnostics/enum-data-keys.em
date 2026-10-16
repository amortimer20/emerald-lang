# Section 8.3 and 12: what keeps an enum carrying data from being a key, whichever
# order the types are declared in.
struct Holder {
    const seen: Set[Download]
    const later: Set[Bag]
}

enum Download {
    waiting
    finished(paths: List[String])
}

struct Bag {
    const items: List[Int]
}

enum Chain {
    end
    link(number: Int, next: Chain)
}

var counts: Dict[Chain, Int] = []
const done: Set[Download] = []
const ok: Set[Mode] = []

enum Mode {
    plain
    sized(width: Int)
}

case Download.waiting {
    when Download.waiting {
    }
}
