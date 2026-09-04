## dog.em sorts before swimmer.em, and a project loads its files in name order. Both the
## checker and the interpreter used to take that order as declaration order: the checker
## read Swimmer's kind before it was set and called the trait a class, and the runtime
## reached for a trait that did not exist yet. Renaming this file to zebra.em fixed the
## program, which is the clearest possible sign the order was never allowed to matter.
class Dog extends Animal with Swimmer

constructor(name: String) { self.name = name }

func speak(): String { return "Woof" }

func stamina(): Int { return 30 }
