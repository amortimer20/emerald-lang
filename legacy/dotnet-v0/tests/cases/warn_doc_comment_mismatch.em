## Javadoc rots because nothing checks it. These are checked.

## @param raduis  a typo no reader would catch
func typo(radius: Int) {}

## @param
func nameless(width: Int) {}

## @param anything  but this takes nothing
func bare() {}

## @returns  and this gives nothing back
func silent(n: Int) {}

typo(1)
nameless(1)
bare()
silent(1)
