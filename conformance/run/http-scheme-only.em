# Section 15.10: only `http://` and `https://` addresses are accepted; another scheme
# raises `HttpError` before any connection is made.
for address in ["ftp://example.com/file", "file:///etc/hosts", "example.com"] {
    try {
        Http.get(address)
    }
    catch error: HttpError {
        print(error.message)
    }
}
