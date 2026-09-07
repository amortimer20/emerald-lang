## Adversarial: one object, one method, eight routes to it. Every route has to reach the
## override -- through the concrete type, the base type, the trait, a trait's own default
## method, a bound callable, a closure, and a collection element. A language where the
## answer depends on the shape of the reference has no dispatch rule at all, only a
## collection of accidents.
##
## The overloaded sibling is here on purpose. Overloads now inherit, so `speak()` and
## `speak(Bool)` live on the same object with only one of them overridden, which is the
## arrangement most likely to make selection pick the wrong member.

trait Speaker {
    abstract func speak(): String
    func twice(): String { return "#{self.speak()} #{self.speak()}" }
}

class Animal with Speaker {
    func speak(): String { return "..." }
    func speak(loud: Bool): String { return "!!!" }
}

class Dog extends Animal {
    override func speak(): String { return "Woof" }
}

var d = Dog()
var as_base: Animal = d
var as_trait: Speaker = d

print(d.speak())
print(as_base.speak())
print(as_trait.speak())

## A default method on the trait calls back into the override, from both sides.
print(d.twice())
print(as_trait.twice())

## A method pulled out as a value stays bound to the object, so it dispatches the same
## way. The annotation is what says which overload is meant -- without it, a name with two
## versions is ambiguous, and the checker says so.
func call(f: func(): String): String { return f() }

var from_dog: func(): String = d.speak
var from_base: func(): String = as_base.speak
print(call(from_dog))
print(call(from_base))
print(call({ d.speak() }))

## As an element of a base-typed collection, beside a genuine base instance.
var pack: List<Animal> = [d, Animal()]
print(pack.map { a => a.speak() }.join(" "))

## The inherited overload the subclass never mentioned is still reachable, and overriding
## its sibling did not redirect it.
print(d.speak(true))
print(as_base.speak(true))
