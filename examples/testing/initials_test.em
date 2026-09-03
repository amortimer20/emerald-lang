@test
func takes_the_first_letter_of_each_word?(): Bool {
    return initials("ada lovelace") == "AL"
}

@test
func copes_with_one_word?(): Bool {
    return initials("prince") == "P"
}

# A test that throws fails, and the message is what gets reported.
@test
func says_what_went_wrong() {
    var got = initials("grace hopper")
    throw "expected GH but got #{got}" unless got == "GH"
}
