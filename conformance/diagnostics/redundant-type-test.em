# Section 4.4: the answer to `is` is known before the program runs when the
# value's type here is already exactly the target. This is a warning
# (Diagnostic.Severity), not an error: it does not stop checking.
var score: Int = 5
if score is Int {
    print("always true")
}
