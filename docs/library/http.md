# Http

`Http` makes one finished web request at a time. There is no client, session, or connection
object to create or close: `Http.get` returns a `Http.Response` once the server has answered.
Use [`examples/http.em`](../../examples/http.em) with an address to try it, and the offline
[`conformance/http/http-api.em`](../../conformance/http/http-api.em) and
[`conformance/http/http-errors.em`](../../conformance/http/http-errors.em) cases for the
complete request and failure behavior.

Every request has a 30-second timeout, accepts only `http://` and `https://` addresses, checks
HTTPS certificates, and limits a response body to 64 MB. Requests are synchronous: the program
waits for its answer. Emerald honors standard `HTTP_PROXY` and `HTTPS_PROXY` environment
settings when the host process provides them, but programs cannot read environment variables or
change proxy settings themselves.

## Requests

```emerald
Http.get(
    url: String,
    query: Dict[String, String] = [],
    headers: Dict[String, String] = [],
    timeout: Duration = Duration(seconds: 30),
    strict: Bool = true
) -> Http.Response

Http.delete(url: String, query:, headers:, timeout:, strict:) -> Http.Response

Http.post(
    url: String,
    body: String? = nothing,
    json: String? = nothing,
    bytes: Bytes? = nothing,
    query: Dict[String, String] = [],
    headers: Dict[String, String] = [],
    timeout: Duration = Duration(seconds: 30),
    strict: Bool = true
) -> Http.Response

Http.put(url: String, body:, json:, bytes:, query:, headers:, timeout:, strict:) -> Http.Response
Http.patch(url: String, body:, json:, bytes:, query:, headers:, timeout:, strict:) -> Http.Response
```

`query:` adds percent-encoded names and values after any query already in `url`, in dictionary
order. `headers:` sends its names and values as given. Emerald supplies `User-Agent:
Emerald/<version>` unless `headers:` supplies one.

`post`, `put`, and `patch` accept at most one body. `body:` is UTF-8 text and supplies
`Content-Type: text/plain; charset=utf-8`; `json:` is already encoded JSON text and supplies
`Content-Type: application/json`; `bytes:` sends binary data without choosing a content type.
A `content-type` header in `headers:` wins over either default. Write `json: Json.encode(value)`
to send an ordinary Emerald value as JSON.

`strict: true` is the default: a 4xx or 5xx answer raises `HttpError`. With `strict: false`, a
completed response always returns and `response.ok?()` tells whether its status is 200 through
299. Network, certificate, timeout, and response-size failures still raise in either mode.

`get` and `delete` follow up to five redirects and expose the final address. A request with a
body is not resent to a new address: its redirect response is returned, or raises in strict
mode.

```emerald
const response = Http.get("https://api.example.com/weather", query: ["city": "São Paulo"])
const weather = response.json()
print(weather.get("current").get("temperature").float())

struct Score {
    const name: String
    const points: Int
}

const saved = Http.post(
    "https://api.example.com/scores",
    json: Json.encode(Score("Ada", 120)),
)
print(saved.status)
```

## Http.Response

```emerald
response.status -> Int
response.reason -> String
response.url -> String
response.headers -> Dict[String, String]
response.bytes -> Bytes
response.text -> String

response.ok?() -> Bool
response.header(name: String) -> String?
response.json() -> Json
```

`status` and `reason` are the server's completed HTTP status, such as `200` and `"OK"`.
`url` is the final address after a followed redirect. Response-header names are lowercase;
`header(name)` accepts any capitalization. Repeated header values are joined with `", "`,
except `set-cookie`, whose values are joined with a newline.

`bytes` is binary response data after ordinary HTTP content decoding (such as gzip), with no
UTF-8 conversion. `text` reads those bytes as UTF-8. `json()` parses the text as `Json`, which
is useful when a response's shape is only known at runtime.

**Raises** `HttpError` when `text` reaches data that is not UTF-8; use `.bytes` instead.
`json()` raises `JsonError` when the text is not JSON, with the response address in its message.

## Http.encode_component(text: String) -> String

Percent-encodes one URL component without treating `/`, `?`, or `&` as URL punctuation:

```emerald
print(Http.encode_component("São Paulo/a?b"))  # S%C3%A3o%20Paulo%2Fa%3Fb
```

Use `query:` for query names and values; it calls this encoding automatically.

## HttpError

`HttpError` extends `RuntimeError` and has `status: Int?`. It is a status number for a strict
4xx or 5xx answer, and `nothing` for every other failure. Catch it when the program can recover
from an unavailable server, timeout, invalid address, error status, unreadable response text,
or an HTTPS certificate that cannot be verified:

```emerald
try {
    Http.get("https://api.example.com/users/404")
}
catch error: HttpError {
    print(error.message)
    if error.status == 404 {
        print("That user does not exist.")
    }
}
```

Certificate errors always keep verification on; Emerald has no `insecure:` escape hatch. Zig's
HTTP transport reports expired, self-signed, and wrong-address certificates through one common
failure, so the message accurately says that the server identity could not be verified rather
than guessing which certificate problem occurred.
