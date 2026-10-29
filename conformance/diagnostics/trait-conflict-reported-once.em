# Section 11.2: a conflict between traits is reported where both are first brought
# together, not again in every subclass or trait built on top.
trait Loud {
    func speak(): String {
        return "LOUD"
    }
}

trait Quiet {
    func speak(): String {
        return "quiet"
    }
}

trait Moody with Loud, Quiet {
}

trait Moodier with Moody {
}

class Person with Moody {
}

class Child extends Person {
}

struct Robot with Moodier {
}
