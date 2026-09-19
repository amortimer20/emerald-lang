# Traits

## A trait is a contract. A member without a body is something every type that
## adopts the trait has to supply; a member with a body is a default.
trait Describable {
    const name: String

    func details(): String

    func describe(): String {
        return "#{self.name}: #{self.details()}"
    }
}

## A struct adopts a trait with `with`. A field supplies `name`, and a method
## marked `@override` supplies `details`.
struct Book with Describable {
    const name: String
    const pages: Int

    @override
    func details(): String {
        return "#{self.pages} pages"
    }
}

## A class can adopt the same trait, and replace a default too.
class Song with Describable {
    const name: String
    const seconds: Int

    constructor(name: String, seconds: Int) {
        self.name = name
        self.seconds = seconds
    }

    @override
    func details(): String {
        return "#{self.seconds // 60} minutes"
    }

    @override
    func describe(): String {
        return "Now playing " + Describable.describe(self)
    }
}

## A list of the trait holds either, and each keeps its own behavior.
const shelf: List[Describable] = [Book("Dune", 412), Song("Blue", 185)]
for item in shelf {
    print(item.describe())
}
