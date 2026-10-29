# Section 3.3: the `?` result rule still applies to an override.
class Light {
    func on?(): Bool {
        return true
    }
}

class Lamp extends Light {
    @override
    func on?(): String {
        return "yes"
    }
}
