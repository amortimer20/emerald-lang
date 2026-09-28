# A module-level declaration that hides one of the language's own built-ins,
# such as `random`, is a warning naming the qualified form. A standard-library
# name, such as `Path` or a `file/` directory, is silent: a program may well
# mean its own. A local such as the parameter `input` hides nothing worth
# reporting. A built-in function, however it is reached, can only be called.
struct Path {
    var text: String
}

const random = 4

func echo(input: String): String {
    const write = input
    return write
}

print(Path(echo("x")), random, File.describe())
print(Emerald.print)
