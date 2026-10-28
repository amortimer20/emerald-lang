# Mistake: empty() without ? (line 3). Source: carry-over from C++.
var names: List[String] = []
if names.empty() {
    print("none")
}
