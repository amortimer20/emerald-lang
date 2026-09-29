try {
    Console.choose("Pick", [])
}
catch error: RuntimeError {
    print(error.message)
}

try {
    Console.choose_many("Pick", [])
}
catch error: RuntimeError {
    print(error.message)
}

try {
    Console.ask_int("Number", minimum: 4, maximum: 2)
}
catch error: RuntimeError {
    print(error.message)
}
