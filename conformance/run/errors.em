class MinorError extends Error {
}

struct Counter {
    var value: Int

    func fail_after_change() {
        self.value += 1
        raise MinorError("changed first")
    }
}

class Holder {
    var counter: Counter
}

func fail() {
    raise MinorError("small problem")
}

func returns_after_cleanup(): Int {
    try {
        return 7
    }
    finally {
        print("return cleanup")
    }
}

try {
    fail()
}
catch error: MinorError {
    print(error.message)
}
finally {
    print("outer cleanup")
}

try {
    print(1 / 0)
}
catch error: RuntimeError {
    print("runtime error caught")
}

try {
    try {
        fail()
    }
    catch error: MinorError {
        raise
    }
}
catch error {
    print("reraised " + error.message)
}

var direct = Counter(0)
try {
    direct.fail_after_change()
}
catch error: MinorError {
    print(direct.value)
}

var holder = Holder(Counter(0))
try {
    holder.counter.fail_after_change()
}
catch error: MinorError {
    print(holder.counter.value)
}

assert returns_after_cleanup() == 7
try {
    assert false, "caught assertion"
}
catch error: AssertionError {
    print(error.message)
}

var loop_count = 0
while true {
    try {
        loop_count += 1
        if loop_count == 1 {
            continue
        }
        break
    }
    finally {
        print("loop cleanup")
    }
}
print("done")
