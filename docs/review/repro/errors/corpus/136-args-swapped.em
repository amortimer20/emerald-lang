# Mistake: arguments in the wrong order (line 5). Source: Altadmri & Brown 2015 (Blackbox), mistake I.
func repeat_word(word: String, times: Int): String {
    return word.repeat(times)
}
print(repeat_word(3, "ha"))
