## @name's argument is written into emitted metadata, so it cannot be computed.
var chosen = "Any"

@name(chosen)
func any?(): Bool { return true }

print(any?())
