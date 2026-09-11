# Section 7.1: variables are visible only from their declarations, and that
# holds inside a function body too. Functions are hoisted; variables are not.

func show() {
    print(limit)
}

const limit = 10
