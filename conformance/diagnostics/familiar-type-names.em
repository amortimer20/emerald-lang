func greet(): void {
    print("hi")
}
func shout(text: str): str {
    return text.upper()
}
var ready: boolean = true
try {
    var n = "x".to_int()
    print(n)
}
catch error: ValueError {
    print("bad number")
}
