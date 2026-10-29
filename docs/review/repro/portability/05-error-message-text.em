# 13.1 says interpreter-detected failures are RuntimeError; no section gives
# their message text, yet a program reads it, and 49 conformance/run cases
# print `.message` of interpreter-raised errors.
const items = [1, 2, 3]
const zero = items.count - 3
for attempt in 0..<4 {
    try {
        case attempt {
            when 0 {
                print(items[5])
            }
            when 1 {
                print(1 // zero)
            }
            when 2 {
                print(9223372036854775807 + items.count)
            }
            else {
                print("x".to_int())
            }
        }
    }
    catch error: RuntimeError {
        print(error.message)
    }
}
