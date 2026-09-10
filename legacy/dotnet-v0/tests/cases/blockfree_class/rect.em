## A class declaration with no braces: the line names the type, and everything below it
## to the end of the file is the body. It removes a nesting level from every file, which
## is the whole reason GDScript reads light — and it is the same declaration with its
## body implied rather than a second way of writing classes.
class Rect

var width: Int
var height: Int

constructor(width: Int, height: Int) {
    self.width = width
    self.height = height
}

func area(): Int { return self.width * self.height }

func square?(): Bool { return self.width == self.height }
