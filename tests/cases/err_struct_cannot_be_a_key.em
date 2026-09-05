## Keys are Int, Float, String or Bool (§3.7). Finding a value again needs hashing, and a
## type's own equals? is not something the lookup can consult yet.
struct P { var x: Int }
var d: Dictionary<P, Int> = [:]
