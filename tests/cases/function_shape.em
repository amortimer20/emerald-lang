# What still fits. A receiver that declares no return does not look at the answer, so
# handing it something that gives one back is not a mistake.

func take(f: func(Int): Int): Int { return f(2) }
func discard(f: func()) { f() }

func double(n: Int): Int { return n * 2 }

func counted(): Int {
    print("ran")
    return 1
}

print(take(double))
print(take({ n => n + 1 }))
discard(counted)
discard { print("block") }
