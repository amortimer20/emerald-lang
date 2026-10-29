# A task in a different (nested) group observes the outer group's failing child.
try {
    Tasks.run { outer =>
        const failing = outer.start { =>
            Program.sleep(Duration(milliseconds: 5))
            raise AssertionError("outer child failed")
        }
        Tasks.run { inner =>
            inner.start { =>
                try {
                    failing.result()
                }
                catch error: AssertionError {
                    print("inner task observed: #{error.message}")
                }
            }
        }
        print("outer block continued")
    }
    print("outer group returned normally")
}
catch error: AssertionError {
    print("outer group raised: #{error.message}")
}
catch error: CancelledError {
    print("outer group raised CancelledError")
}
