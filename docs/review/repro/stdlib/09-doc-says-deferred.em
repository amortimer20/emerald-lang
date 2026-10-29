# Finding 09: the docs call words, letter?, and digit? deferred, yet they run and are documented.
# string.md opens "`letter?`, `digit?`, `words`, `title_case`, and case-insensitive comparison
# remain deferred" and then documents letter?/digit?/words; rewrite-context 9.2 says the same in
# its paragraph on code_points while its vocabulary list and character-test paragraph include them.
# Expected: the "deferred" sentences name only what is still missing (title_case,
# case-insensitive comparison).
print("  the  quick ".words(), "\u{E9}".letter?(), "7".digit?())
