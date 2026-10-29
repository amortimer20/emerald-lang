# Section 13.2: bare `raise` inside a catch re-raises the same value with its original
# failure location, so the trace points into `load`, not at the `raise`.
func load() {
    raise Error("disk is full")
}

func run() {
    try {
        load()
    }
    catch error {
        print("cleaning up")
        raise
    }
}

run()
