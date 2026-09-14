# Section 6.3: every arm of a `case` is written the same way, `else` comes
# last, and a `case` without a subject takes one condition per arm.

case 1 {
    when 1 then 2
    when 2 {
        print(2)
    }
}

case 1 {
    else {
    }
    when 1 {
    }
}

case {
    when true, false {
    }
}

case 1 {
    when 1 then 2
}

const block_as_value = case 1 {
    when 1 {
    }
}

case 1 {
    print(1)
}

case 1 {
}

const same_line = case 1 {
    when 1 then 2 else then 3
}
