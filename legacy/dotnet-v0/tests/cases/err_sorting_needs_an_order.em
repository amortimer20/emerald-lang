## A type that has not said how it orders cannot be sorted, and says so on the line that
## asked -- not on the line where the class happens to be declared.
##
## Two things used to go wrong here. The diagnostic was swallowed: .NET wraps whatever a
## comparer throws in "Failed to compare two elements in the array", so a written message
## arrived as an internal compiler error blaming Emerald for the program's omission. And
## the line was wrong, because the call stamps its line before evaluating its receiver --
## which is right for a failure inside the receiver and wrong for a failure in the call
## itself.
class Plain {
    var n: Int
    constructor(n: Int) { self.n = n }
}

print([Plain(1), Plain(2)].sort())
