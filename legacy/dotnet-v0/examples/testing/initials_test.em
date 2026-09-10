@test
func takes_the_first_letter_of_each_word() {
    assert initials("ada lovelace") == "AL"
}

@test
func copes_with_one_word() {
    assert initials("prince") == "P"
}

# A test can still return a Bool, or throw its own message. assert is the shortest of
# the three and the only one that explains itself.
@test
func still_works_the_old_way?(): Bool {
    return initials("grace hopper") == "GH"
}
