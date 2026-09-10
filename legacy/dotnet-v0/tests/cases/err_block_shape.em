## A block of the wrong shape. An unannotated block parameter has no type to print, so
## the shapes alone read as func() against func(?) — true, and no help about what to do.
func run(action: func()) {
    action()
}

run { x => print(x) }
