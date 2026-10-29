# Mistake: Python str as a type (line 2). Source: carry-over from Python.
func shout(text: str): str {
    return text.upper()
}
print(shout("hi"))
