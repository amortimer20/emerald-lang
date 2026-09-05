## Indexing had a bounds check and the one method that removes by index did not, so an
## ordinary mistake reached .NET and came back as "this is a bug in Emerald".
var xs = [1]
xs.remove_at(9)
