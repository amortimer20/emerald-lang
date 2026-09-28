const base = Program.arguments[0]

try {
    Http.get("#{base}/missing")
} catch error: HttpError {
    print(error.status)
    print(error.message.contains?("404"))
}

try {
    const text = Http.get("#{base}/binary").text
} catch error: HttpError {
    print(error.status == nothing)
    print(error.message.contains?("not UTF-8"))
}

try {
    Http.post("#{base}/echo", body: "one", json: "{}")
} catch error: HttpError {
    print(error.message)
}

try {
    Http.get("#{base}/not-json").json()
} catch error: JsonError {
    print(error.message.contains?("not-json"))
}

try {
    Http.get("#{base}/slow", timeout: Duration(milliseconds: 10))
} catch error: HttpError {
    print(error.message.contains?("timeout"))
}

try {
    Http.get("#{base}/redirect-loop")
} catch error: HttpError {
    print(error.message.contains?("redirected more than 5"))
}

try {
    Http.get("weather")
} catch error: HttpError {
    print(error.message.contains?("not a web address"))
}

try {
    Http.get("ftp://example.com")
} catch error: HttpError {
    print(error.message.contains?("http:// and https://"))
}
