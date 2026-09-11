# A trailing `if` would put a declaration in a scope that ends on the same
# line, so it could never be used.

var bonus = 10 if true
