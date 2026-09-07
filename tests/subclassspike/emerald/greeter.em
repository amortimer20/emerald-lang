## The override's body, and the only Emerald source in this milestone. An ordinary
## function, checked by the real Scanner, Parser and Checker, with nothing about it
## naming a foreign type or a base class -- the driver decides which C# method this
## becomes an override of. Emerald itself has no syntax yet for subclassing a foreign
## type; that is real interop work, deferred on purpose. This milestone asks a narrower
## question: once such a body exists, checked and correct, can the emitter graft it onto
## a real override slot on a real CLR base class, so that C# code calling the ordinary
## method the base class already has ends up running this.
func greet(): String { return "Hello from Emerald" }
