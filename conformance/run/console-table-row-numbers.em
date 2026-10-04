func message(rows: List[List[String]], header: List[String] = []): String {
    try {
        Console.table(rows, header: header)
    }
    catch error: RuntimeError {
        return error.message
    }
    return "no error"
}
print(message([["a", "b"], ["c", "d"]], ["x"]))
print(message([["a"]], ["x", "y"]))
print(message([["a"], ["b", "c"]]))
print(message([["a", "b"], ["c"]]))
print(message([["a\nb"]], ["x"]))
print(message([["a"]], ["x\ny"]))
