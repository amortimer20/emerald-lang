## The operator traits ship with the compiler, so a program cannot quietly replace one.
trait Addable {
    abstract func combine(other)
}

print("hi")
