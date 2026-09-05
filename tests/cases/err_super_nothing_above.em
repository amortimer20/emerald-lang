## super is bound like self — an ordinary name, present only where there is something
## above to reach. "Declare it first: var super = ..." is the least helpful thing that
## could be said to whoever wrote this.
class Lonely {
    func speak(): String { return super.speak() }
}
