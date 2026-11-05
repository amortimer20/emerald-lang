# Section 14.1: the built-in `exit()` ends the program, so, like `raise`, it
# ends its path, and code after it can never run.
print("one")
exit(0)
print("two")

func stop() {
    exit(1)
    print("never")
}

func search(numbers: List[Int]): Int {
    while true {
        for number in numbers {
            return number if number > 10
        }
        exit(2)
    }
    print("searched")
}

# Near misses: a guarded `exit`, and a method that happens to be named `exit`,
# carry on.
func check(ready: Bool) {
    exit(3) if not ready
    print("ready")
}

class Door {
    func exit() {
        print("leaving")
    }
}

func leave(door: Door) {
    door.exit()
    print("left")
}
