# Make one HTTP request and show its finished response.
# Run it with `emerald run examples/http.em -- https://example.com`.

if Program.arguments.count == 0 {
    print("Usage: emerald run examples/http.em -- <http-or-https-address>")
}
else {
    try {
        const response = Http.get(Program.arguments[0], strict: false)
        print("#{response.status} #{response.reason}")
        print(response.url)
        if response.ok?() {
            print(response.text)
        }
        else {
            print("The server did not accept this request.")
        }
    }
    catch error: HttpError {
        print(error.message)
    }
}
