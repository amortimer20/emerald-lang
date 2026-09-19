# Section 16.1's annotations and section 10.7's `super`, where they cannot go.
@overide
class A {
    @banana
    func a() {
    }
    @test
    func b() {
    }
}
@abstract
struct S {
}
@override
func top() {
}
class B {
    @override
    var x: Int = 0
    @abstract
    constructor() {
        self.x = 1
    }
    @override
    func B.make(): B {
        return B()
    }
}
struct T {
    @override
    func f() {
    }
    func g() {
        super.g()
    }
}
@abstract
class A {
    @abstract
    func area(): Float {
        return 1
    }
    func perimeter(): Float
    func A.make() {
        super.make()
    }
}
class C extends A, B {
}
class D extends List[Int] {
}
class E {
    func f() {
        super.f()
        const x = super
    }
}
func g() {
    super.h()
}
