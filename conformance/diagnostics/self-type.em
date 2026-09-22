# Section 11.4: `Self` means the type a method belongs to, so it is written
# only in a method's parameter and result types. Implementations match a
# trait's `Self` with the adopting type.

struct Node {
    const value: Int
    const next: Self
}

trait Sized {
    const smaller: Self

    func grown(): Self {
        const copy: Self = self
        return 5
    }
}

func helper(): Self {
    return 1
}

trait Combines {
    func add(other: Self): Self
}

struct Wrong with Combines {
    const n: Int

    @override
    func add(other: Int): Wrong {
        return Wrong(self.n + other)
    }
}

# A class that adopts a trait takes its own type where the trait has `Self`,
# so a base class's method written for the base class does not supply it.
class Shape {
    func add(other: Shape): Shape {
        return other
    }
}

class Circle extends Shape with Combines {
}

# Through a value seen as a trait, a member that takes `Self` cannot be
# given anything, since the value could be of any type adopting the trait.
func combine(a: Combines, b: Combines) {
    print(a.add(b))
    const adding = a.add
}

trait Doubling with Combines {
    func doubled(): Self {
        return self.add(self)
    }
}

struct Count with Doubling {
    const n: Int

    @override
    func add(other: Self): Self {
        return Count(self.n + other.n)
    }
}

print(Doubling.doubled(Count(1)))
