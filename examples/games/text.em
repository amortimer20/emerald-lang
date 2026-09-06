# No class line, so this file is a module: every member is reached as Text.<name>
#
# This was four functions longer. Nothing in the language could make a string a given
# width, so pad_left, pad_right, center and repeat were written here first — which is
# what put them in the standard library, where they are counted in graphemes and agree
# with .count() without every project having to get that right for itself.

# A heading with a line under it, because every one of the games opens with one.
func banner(title: String) {
    print()
    print(title)
    print("=".repeat(title.count()))
}
