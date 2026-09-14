class Config {
    const Config.value: Int = 1 // 0
}

try {
    print(Config.value)
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(Config.value)
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(Broken.value)
}
catch error: RuntimeError {
    print(error.message)
}

try {
    print(Broken.value)
}
catch error: RuntimeError {
    print(error.message)
}
