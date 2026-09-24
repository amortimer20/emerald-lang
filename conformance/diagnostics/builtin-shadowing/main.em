# A project name that hides a built-in is a warning naming the qualified form:
# a module-level declaration, or a top-level directory. A local such as the
# parameter `input` hides nothing worth reporting. A built-in function, however
# it is reached, can only be called.
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
