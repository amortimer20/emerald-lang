# No class line, so this file is a module: every member is reached as SoundUtils.<name>
func loudly(text: String): String {
    return text.upper() + "!"
}

func repeat(text: String, times: Int): String {
    var out = ""
    for i in 1..times {
        out += text
    }
    return out
}
