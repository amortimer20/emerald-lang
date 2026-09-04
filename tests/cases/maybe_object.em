## .or and .must on a class instance. Every other type reaches them through one shared
## path, and an instance reached its own — so a City? holding a real City answered
## "no member named or on City", which is the null-reference message this design exists
## to make impossible, arriving from the escape hatch built to avoid it.
class City {
    var name: String
    constructor(name: String) { self.name = name }
}

var found: City? = City("Leeds")
var absent: City? = nothing

print(found.or(City("unknown")).name)
print(absent.or(City("unknown")).name)
print(found.must().name)

## The fallback is only built when it is needed — .or takes a value, so this is not
## lazy, but the present value is still the one that comes back.
print(absent.must().name)
