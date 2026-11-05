func do(action: func(): Nothing) {
    action()
}

do { => print("ran") }
