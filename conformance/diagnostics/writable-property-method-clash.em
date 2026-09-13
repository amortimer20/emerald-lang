# A writable property and a method share one name space. The method is the
# first registered declaration here, so the losing property's absent setter
# must not be checked as though it existed.
struct Gauge {
    func level() {
    }

    var level: Int {
        get {
            return 0
        }
        set {
        }
    }
}

# The same missing-setter path occurs when a read-only property wins the name
# and a later writable property is skipped.
struct Meter {
    const reading: Int {
        return 0
    }

    var reading: Int {
        get {
            return 1
        }
        set {
        }
    }
}
