# Section 14.3: `Self` in a nested type's method means the nested type, not the type
# around it.
class Theme {
    struct Pair {
        var left: Int

        func copy(): Self {
            return Theme.Pair(left: self.left)
        }
    }
}

const theme: Theme = Theme.Pair(left: 1).copy()
