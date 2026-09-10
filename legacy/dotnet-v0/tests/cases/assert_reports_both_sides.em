## §3.5's example: the report has to name the source and what each side actually was.
## A function receiving `false` could say neither.
func clamp(value: Int, low: Int, high: Int): Int {
    return if value < low then low else value
}

assert clamp(15, 0, 10) == 10
