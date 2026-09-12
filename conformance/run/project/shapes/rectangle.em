const unit = "cm"

func area(width: Int, height: Int): Int {
    return width * height
}

func perimeter(width: Int, height: Int): Int {
    return _twice(width) + _twice(height)
}

## Private to this file, because its name starts with an underscore.
func _twice(value: Int): Int {
    return value * 2
}
