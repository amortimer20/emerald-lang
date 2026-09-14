raise 1
raise

try {
}
catch error: Int {
}

try {
}
catch error {
}
catch later: Error {
}

assert 1, 2

func cleanup() {
    try {
    }
    finally {
        return
    }
}

var assigned_inside: Int
try {
    assigned_inside = 1
}
finally {
    print(assigned_inside)
}

var assigned_by_cleanup: Int
try {
}
finally {
    assigned_by_cleanup = 1
}
print(assigned_by_cleanup)

@test
func parameterized(value: Int) {
}

@test
func returns_value(): Int {
    return 1
}

class DetailedError extends Error {
    var code: Int

    constructor(message: String, code: Int) {
        super(message)
        self.code = code
    }
}

class MissingConstructor extends DetailedError {
}

func cannot_break_from_cleanup() {
    while true {
        try {
        }
        finally {
            break
        }
    }
}

func cannot_continue_from_cleanup() {
    while true {
        try {
        }
        finally {
            continue
        }
    }
}
