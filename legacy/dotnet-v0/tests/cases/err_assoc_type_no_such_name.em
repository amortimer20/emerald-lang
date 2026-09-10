## A type declaration has to answer a question a trait actually asked. Mixing in nothing
## that declares Value leaves nothing for this line to be satisfying.
class Thing {
    type Value = Int
}
