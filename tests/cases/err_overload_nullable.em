## A String is also a String?, so a String argument matches both.
func f(s: String): String { return "took String" }
func f(s: String?): String { return "took String?" }
