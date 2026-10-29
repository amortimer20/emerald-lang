# Finding P1. Path.join is lexical with "/" on every platform, but name,
# stem, extension, parent and absolute? use the host's rules, so the same
# lexical path splits differently on Windows.
print(Path.name("notes\\week1.txt"), "|", Path.parent("notes\\week1.txt"), "|", Path.extension("a\\b.c\\d"))
print(Path.absolute?("C:\\Users\\ada"), Path.absolute?("C:/Users/ada"), Path.absolute?("\\\\server\\share"))
print(Path.parent(Path.join(["C:\\Users\\ada", "notes.txt"])))
