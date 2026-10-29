# Section 11.2: requirements of the same name with different types conflict.
trait Counted {
    const size: Int
}

trait Measured {
    const size: Float
}

struct Box with Counted, Measured {
    const size: Int = 1
}
