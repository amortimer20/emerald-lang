# A trait may not declare a nested type (14.3), and a nested type is never
# inherited or, unless it is a class, abstract.
class Outer {
    @override
    struct Replaced {}
    @abstract
    enum Fixed { only }
}

trait Host {
    struct Guest {}
}
