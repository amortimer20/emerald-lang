# Unannotated is allowed everywhere else, and refused here: the language calls this one
# for you, so a to_string quietly handing back something that is not text would print
# the plain form with nothing said.
class Tag {
    func to_string() {
        return 3
    }
}
