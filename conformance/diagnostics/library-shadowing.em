# A program's own `File` hides the standard library's silently, since a
# program may well mean its own. Reaching for something only the library's has
# is where the hiding matters, so that is where it is explained.
struct File {
    const name: String
}

print(File.read("notes.txt"))
