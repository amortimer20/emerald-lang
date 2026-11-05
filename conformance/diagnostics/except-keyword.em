try {
    const n = "x".to_int()
    print(n)
}
except error: RuntimeError {
    print("bad number")
}
