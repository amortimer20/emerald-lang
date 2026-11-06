# The declarations of the `example` library: the Emerald API a beginner sees.
# Everything C-shaped stays in example.c; this file is where names, defaults,
# errors, and documentation are written (docs/vendor-libraries.md).

class ExampleError extends Error {
    constructor(message: String) {
        super(message)
    }
}

class Example {
    const _id: Int

    # Native: the sum of two integers. A native is a private function whose
    # comment starts with `Native:` and whose body is a stand-in; the module's
    # function of the same name runs instead.
    func Example._add(first: Int, second: Int): Int { return 0 }

    ## The sum of two numbers.
    func Example.add(first: Int, second: Int): Int {
        return Emerald.Example._add(first, second)
    }
}
