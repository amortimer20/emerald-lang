# Section 14.2: a program's own `print_error` hides the built-in, with a
# warning, and the built-in stays reachable as `Emerald.print_error`.
func print_error(message: String) {
    Emerald.print_error("error: #{message}")
}

print_error("disk full")
