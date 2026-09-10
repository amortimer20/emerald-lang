## A trait is a contract, and until now only the member's *name* was checked against it.
## Wrong arity, wrong parameter types and wrong return type were all accepted — for traits
## and for abstract classes alike — which made a trait's declared shape a comment.
trait Named {
    abstract func label(): String
}

class Tag with Named {
    func label(size: Int): String { return "x" }
}
