# The built-ins live in the `Emerald` namespace, implicitly imported into every
# file. A name the program declares wins; the built-in stays reachable qualified.
struct File {
    var name: String
}

const mine = File("notes")
print(mine)
print(Emerald.File.exists?("conformance/run/definitely-not-a-file.txt"))

const failure: Emerald.RuntimeError = Emerald.RuntimeError("boom")
print(failure.message)

using Handle = Emerald.FileHandle
func describe(handle: Handle?): String {
    return if handle == nothing then "no handle" else "a handle"
}
print(describe(nothing))
