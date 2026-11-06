# Section 6.5: `return` leaves only the block it is written in. A method that
# ignores what its block gives back carries on with the next item, so the
# function around it does not return.
func index_of_name(names: List[String], wanted: String): Int {
    names.each_with_index { name, index =>
        if name == wanted {
            return index
        }
    }
    return -1
}

func first_big(numbers: List[Int]): Int {
    numbers.each { number =>
        return number if number > 10
    }
    5.times { round =>
        return round if round == 3
    }
    return 0
}

# Near misses: a bare `return`, which skips to the next item; a `return` in a
# block whose value `map` keeps; and a `return` in a nested function.
func shout_all(names: List[String]) {
    names.each { name =>
        return if name.empty?()
        print(name.upper())
    }
    const lengths = names.map { name =>
        return name.count
    }
    print(lengths)
    names.each { name =>
        func label(): String {
            return "<#{name}>"
        }
        print(label())
    }
}
