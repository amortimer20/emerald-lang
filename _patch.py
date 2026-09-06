edits = [
    ("games/main.em" if False else "examples/games/main.em", [
        ("#   emerald run games/main.em      play\n#   emerald test games             check the rules",
         "#   emerald run examples/games/main.em      play\n#   emerald test examples/games             check the rules"),
    ]),
    ("README.md", [
        ("./tests/gamecheck.sh        # games/ — the rules tested, and each game played through",
         "./tests/gamecheck.sh        # examples/games/ — rules tested, and each game played through"),
    ]),
    ("tests/gamecheck.sh", [
        ("# The games in games/ are the first programs written in Emerald that are programs rather",
         "# The games in examples/games/ are the first programs written in Emerald that are programs"),
        ("# than demonstrations of a feature. They are checked two ways: the rules have their own",
         "# rather than demonstrations of a feature. They are checked two ways: the rules have their"),
        ("# @test functions, and each game is played through to the end with scripted input.",
         "# own @test functions, and each game is played through to the end with scripted input."),
        ('games="$root/games"', 'games="$root/examples/games"'),
    ]),
    ("tests/examples.sh", [
        ("""        hello)          input=$'Ada\n' ;;""",
         """        hello)          input=$'Ada\n' ;;
        # The games are a menu; quitting it proves the project loads and the menu runs.
        # tests/gamecheck.sh is the one that plays them.
        games)          input=$'q\n' ;;"""),
    ]),
]
for path, pairs in edits:
    s = open(path, encoding="utf-8").read()
    for old, new in pairs:
        assert old in s, (path, old[:60])
        s = s.replace(old, new, 1)
    open(path, "w", encoding="utf-8", newline="\n").write(s)
print("ok")
