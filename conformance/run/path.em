# Section 15.3's lexical path operations do not touch the filesystem.
print(Path.join(["notes", "2026", "draft.txt"]))
print(Path.name("notes/2026/draft.txt"))
print(Path.stem("notes/2026/draft.txt"))
print(Path.extension("notes/2026/draft.txt") + "|" + Path.extension(".gitignore"))
print(Path.parent("notes/2026/draft.txt") + "|" + Path.parent("draft.txt"))
print(Path.absolute?("notes/draft.txt"), Path.absolute?("/notes/draft.txt"))
