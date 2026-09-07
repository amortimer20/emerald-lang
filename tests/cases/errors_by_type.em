# Typed catch: a program declares its own errors and says which one it handles.
# Error is an ordinary class from the prelude, so `extends` is all it takes.

class NotFound extends Error { }

class Rejected extends Error {
    var field: String

    constructor(message: String, field: String) {
        super(message)
        self.field = field
    }
}

func lookup(key: String) {
    throw NotFound("no entry for #{key}") if key == "ghost"
    throw Rejected("that is not a name", "name") if key == ""
    throw "something else went wrong" if key == "odd"
    print("found #{key}")
}

for k in ["fine", "ghost", "", "odd"] {
    try {
        lookup(k)
    }
    catch e: NotFound {
        print("missing: #{e.message}")
    }
    catch e: Rejected {
        # The declared type is what the handler gets, so its own fields are reachable.
        print("rejected #{e.field}: #{e.message}")
    }
    catch e {
        print("other: #{e.message}")
    }
}

# A failure the compiler raised is a plain Error, so a bare clause takes it and a
# clause naming a program's own error correctly declines it.
try {
    print("banana".to_int())
}
catch e: NotFound {
    print("never")
}
catch e {
    print("runtime: #{e.message}")
}

# An error prints as its own text rather than as <Error>.
print(NotFound("printed directly"))

# An error is an instance like any other, so is and type_name work on it. Held as the
# base, which is the case where asking is worth anything.
var problem: Error = Rejected("bad", "age")
print(problem is Rejected)
print(problem.type_name())
