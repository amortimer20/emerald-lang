using E = Errors

try {
    E.fail()
}
catch error: E.SmallError {
    print(error.message)
}
