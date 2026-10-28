# Mistake: default instead of else (line 7). Source: carry-over from Java/C.
var day = 3
case day {
    when 1 {
        print("Mon")
    }
    default {
        print("other")
    }
}
