# HTTP client: design and implementation plan

Status: accepted, 2026-09-27. The user accepted every recommendation, including decision 2
(a): an error status raises `HttpError` by default. Slices 1 and 2 are complete; slice 3 is next. Rewrite-context 15.7
lists a synchronous HTTP client as the next standard-library item after JSON. This plan sets
out the API, what an HTTP failure looks like to a beginner, how the work is tested without
the internet, and the order of work. The executor makes the remaining judgement calls
within a slice, and records each one under that slice's "Settled while building" note. At the
start of each slice, reread `git status`, the recent `git log`, and docs/handoff.md.

## What beginner programs need

The API is judged by these programs. Each should read naturally, and each failure should
say what happened in words a beginner can act on.

```emerald
# Ask a web API a question and use the answer.
const response = Http.get("https://api.example.com/weather", query: ["city": "São Paulo"])
const weather = response.json()
print(weather.get("current").get("temperature").float())

# Decode the answer straight into the program's own types.
struct Joke {
    const setup: String
    const punchline: String
}

const joke = Json.decode(Http.get("https://api.example.com/jokes/random").text, as: Joke)
print(joke.setup)
print(joke.punchline)

# Send data to a server.
struct Score {
    const name: String
    const points: Int
}

const saved = Http.post("https://api.example.com/scores", json: Json.encode(Score("Ada", 120)))
print(saved.status)                         # 201

# Handle a failure the program expects.
try {
    Http.get("https://api.example.com/users/404")
} catch error: HttpError {
    print(error.message)                    # the server answered 404 Not Found for ...
}

# Download a file.
File.write_binary("logo.png", Http.get("https://example.com/logo.png").bytes)
```

## Principles

1. **One call for one request.** `Http.get(url)` does the whole round trip and returns a
   finished response. There are no client objects, sessions, or connection handles for a
   beginner to create or close; connection reuse happens underneath.
2. **Failures are loud and explained.** A missing server, a refused connection, a timeout, an
   untrusted certificate, and (by default, decision 2) an error status are each a `HttpError`
   whose message says what happened, to which address, and what to try.
3. **Safe by default, with no switch to turn safety off.** HTTPS certificates are always
   verified against the operating system's trusted roots (decision 3). Every request has a
   timeout. A response body has a size limit.
4. **It fits what is already here.** `Json` reads the answers (`response.json()`,
   `Json.decode(response.text, as: T)`), `Duration` sets timeouts, `Bytes` holds binary
   bodies, and `File` saves them.
5. **The existing vocabulary.** Named arguments with defaults (7.3), a `Dict` for headers
   and query parameters, and an error class per library (`FileError`, `JsonError`), as the
   rest of the standard library does.

## Verified constraints (checked against source, 2026-09-27)

- **Zig 0.16's `std.http.Client`** does HTTP/1.1 over TCP, with TLS 1.2/1.3 from
  `std.crypto.tls`. It loads the system's root certificates itself (`Certificate.Bundle
  .rescan`: Linux, macOS, Windows, FreeBSD, and OpenBSD), follows up to 3 redirects for a
  request without a body, decompresses gzip, deflate, and zstd, pools connections, and reads
  `HTTP_PROXY`/`HTTPS_PROXY` through `initDefaultProxies`. It has no HTTP/2.
- **Timeouts are not built in.** `fetch` and `request` take no timeout; only
  `connectTcpOptions` does, and only for connecting. Reading a slow response has no limit.
- **The interpreter runs on `std.Io.Threaded.global_single_threaded`.** Racing a request
  against a timer needs `Io.concurrent` and `Future.cancel`, which a single-threaded `Io`
  may refuse (`ConcurrentError`). Slice 1 must prove a whole-request timeout before anything
  is built on it (see Risks).
- **`std.http.Server`** can serve plain HTTP from a thread in a test, so every test can run
  against a local server. Zig has no TLS server, so HTTPS can only be tested against real
  hosts, in an opt-in check that is never part of `zig build test`.
- **`Program` has no environment variables** (only `arguments` and `sleep`), so a test
  program learns the local server's address from `Program.arguments[0]`.
- **Named parameters may default to an empty `Dict` and to a `Duration`**, checked with a
  probe: `query: Dict[String, String] = []`, `timeout: Duration = Duration(seconds: 30)`.
- **No general overloading (7.3).** One function cannot take either a `String` or a `Json`
  body, so request bodies are named: `body:` for text, `json:` for JSON text, `bytes:` for
  binary.
- **`Json.encode` and `Json.decode` must be called by name (15.9).** `Http.post` cannot take
  an arbitrary value to encode, so the program encodes it: `json: Json.encode(value)`.
- **An error class can carry fields** beyond `message`, as any class can; `HttpError` adds
  `status` (below).

## Proposed API

All in the `Emerald` namespace.

```emerald
# Requests. Each returns a finished Http.Response.
Http.get(url: String, query: Dict[String, String] = [], headers: Dict[String, String] = [],
         timeout: Duration = Duration(seconds: 30), strict: Bool = true): Http.Response
Http.delete(url, query:, headers:, timeout:, strict:)             # the same parameters
Http.post(url: String, body: String? = nothing, json: String? = nothing, bytes: Bytes? = nothing,
          query:, headers:, timeout:, strict:): Http.Response
Http.put(...)                                                    # post's parameters
Http.patch(...)                                                  # post's parameters

# The response.
response.status: Int                 # 200
response.reason: String              # "OK"; the standard phrase for the status
response.ok?(): Bool                 # status is 200 through 299
response.url: String                 # the final address, after any redirects
response.headers: Dict[String, String]   # names in lowercase, in the order received
response.header(name: String): String?   # any capitalization of the name
response.text: String                # the body as UTF-8 text
response.bytes: Bytes                # the body exactly as received
response.json(): Json                # Json.parse(text), with the response's address in errors

# Encoding a piece of an address.
Http.encode_component(text: String): String     # "São Paulo" -> "S%C3%A3o%20Paulo"

# Failures.
class HttpError extends RuntimeError {
    const status: Int?               # the status for an error status; nothing otherwise
}
```

- **Only one body at a time.** Passing two of `body:`, `json:`, and `bytes:` is a
  `HttpError` naming both. `json:` sends `Content-Type: application/json` and `body:` sends
  `text/plain; charset=utf-8`, unless `headers:` gives a `Content-Type`.
- **`query:`** is appended to the address, each name and value percent-encoded, in
  dictionary order, after any query the address already has.
- **`headers:`** are sent as given. Emerald sends `User-Agent: Emerald/<version>` unless the
  program gives its own.
- **Redirects** are followed, up to 5, for `get` and `delete`; `response.url` is the final
  address. A request with a body is not re-sent to a new address (Zig's own rule); its 3xx
  response is returned, or raised when `strict`.
- **`response.headers`** joins a repeated header's values with `", "`, as HTTP allows for
  every header except `Set-Cookie`, whose values are joined with `"\n"`.
- **`text`** raises `HttpError` when the body is not UTF-8, naming `bytes` as the way to read
  it. Other character sets are out of scope for this milestone.
- **The body limit** is 64 MB; a larger response raises `HttpError` saying how large it was.
- **Only `http` and `https`.** Any other scheme, or text that is not an address at all, is a
  `HttpError` naming what was wrong with it.

## Decisions

All five were accepted as recommended on 2026-09-27.

1. **Name: `Http`,** not `HTTP` or `Net::HTTP`, matching `Json` (15.9) and the planned
   `Csv`: Emerald writes type names as words. Alternative: `HTTP`, which Swift and Go use,
   at the cost of a second capitalization rule.
2. **An error status raises by default (the main decision).** With `strict: true`, the
   default, a 4xx or 5xx response raises `HttpError` (`the server answered 404 Not Found for
   https://api.example.com/users/404`), whose `status` is `404`. With `strict: false`, every
   response is returned, and the program checks `response.ok?()` or `response.status`
   itself.
   - **(a) Recommended: raise by default.** A beginner who forgets to check the status would
     otherwise feed an error page to `json()` and get a confusing parse error far from the
     cause, or silently save it to a file. Raising puts the explanation where the problem is,
     which is 13's and 17's philosophy of loud, explained failures. Python's `requests`
     reached the same conclusion from the other side: `raise_for_status()` exists because
     everyone forgets it.
   - **(b) Never raise for a status,** as Python's `requests`, JavaScript's `fetch`, and
     Ruby's `Net::HTTP` do. It is familiar to experienced programmers, but it makes every
     beginner program's first mistake silent.
3. **Certificates are always verified,** with no option to turn that off. An untrusted,
   expired, or mismatched certificate is a `HttpError` explaining which it is. Alternative:
   an `insecure: true` escape hatch, as many libraries have. It is also what gets copied
   from forums and left in, and a beginner has no way to judge when it is safe.
4. **Proxies come from the environment.** `HTTP_PROXY`, `HTTPS_PROXY`, and their lowercase
   forms are honored, through Zig's `initDefaultProxies`, because school networks often
   require a proxy and a student cannot change the program's code to reach one. There is no
   proxy parameter. Alternative: ignore proxies until a program needs them.
5. **Headers are a plain `Dict[String, String]` with lowercase names,** plus
   `response.header(name)` for looking one up in any capitalization. Alternative: a
   dedicated `Http.Headers` type that ignores case itself. It would be more exact, but it is
   one more type to learn for something a lowercase dictionary already does, as HTTP/2 itself
   lowercases every header name.

## Errors

`HttpError` extends `RuntimeError`. Every message names the address. Messages to match in
wording, not necessarily word for word:

| Failure | Message |
| --- | --- |
| Not an address | `"weather" is not a web address; write the whole address, as in "https://example.com/weather"` |
| Other scheme | `Http can only use http:// and https:// addresses, not ftp://` |
| Unknown host | `could not find the server "api.exmple.com"; check the spelling of the address` |
| Refused | `could not connect to api.example.com: nothing is accepting connections on port 443` |
| Timed out | `https://api.example.com/slow did not answer within 30 seconds; pass a longer timeout: if it is expected to be slow` |
| Certificate | `could not verify the identity of api.example.com: its certificate has expired` (or: is not trusted, is for a different address) |
| Error status | `the server answered 404 Not Found for https://api.example.com/users/404` |
| Too large | `the response from https://example.com/huge is larger than 64 MB` |
| Not text | `the response from https://example.com/logo.png is not UTF-8 text; read it with .bytes instead` |
| Two bodies | `pass only one of body:, json:, and bytes:` |
| Too many redirects | `https://example.com/loop redirected more than 5 times` |

`response.json()` raises `JsonError` for text that is not JSON, and its message begins with
the response's address.

## Implementation approach

- **A native layer, `src/Http.zig`,** independent of the interpreter, as `src/Regex.zig` and
  `src/Json.zig` are: one function that performs a request (method, URL, headers, body,
  timeout, limits) and returns either a finished result (status, reason, final URL, headers,
  body) or a problem the interpreter turns into a `HttpError` message. A future compiled
  backend reuses it.
- **One `std.http.Client` per program run,** created on the first request and deinitialized
  when the interpreter finishes, so connections and the loaded certificate bundle are reused.
- **The prelude** holds `Http` (type-level functions only), the nested `Http.Response`
  struct, and `HttpError`, over positional natives in `Interpreter.callHttp`, as
  `callRegex` and `callJson` do. `Http.Response` is built natively, like `Regex.Match`, and
  cannot be built by a program; give it the same specific hint `Regex.Match` has in the
  checker's "is not built by calling it" report ("Get one from `Http.get` or another
  request"), since `builtinFactory` only searches a type's own functions.
- **Startup cost.** The prelude grows again. Measure `print(1)` before and after each slice,
  as the JSON slices did, and record it.

## Slices

Each slice is runnable and committed on its own, with AGENTS.md's validation and the
rewrite-context text written in the same change.

1. **The native request, and the test server.** `src/Http.zig` over `std.http.Client`: GET
   and POST, headers, bodies, redirects, decompression, the body limit, and a whole-request
   timeout proven to work on the interpreter's `Io` (see Risks), with every failure mapped
   to a problem kind and message. A local test server in Zig (`std.http.Server` on
   `127.0.0.1`, port 0, on a thread) with scripted routes: statuses, echoing the request's
   method, headers, and body, redirects and a redirect loop, a slow route, a gzip body, a
   chunked body, a large body, and a non-UTF-8 body. Zig unit tests of `Http.zig` against it.
   No Emerald-facing API yet.

   **Settled while building (2026-09-27):** the interpreter's
   `std.Io.Threaded.global_single_threaded` rejects `Io.Select.concurrent` with
   `error.ConcurrencyUnavailable`, exactly as its source documents. The first fallback is
   therefore used: `Http.Client` owns a worker-backed `std.Io.Threaded`, races every request
   against `Io.sleep` on its monotonic `.awake` clock, and calls `cancelDiscard` before it
   returns. This gives the deadline cancellation path a real test rather than trusting a
   connect-only timeout. Zig 0.16 calls its monotonic clock `.awake`, not `.monotonic` as the
   prose shorthand above did.
2. **The Emerald API.** `Http.get`, `delete`, `post`, `put`, `patch`, `Http.Response`,
   `Http.encode_component`, `HttpError`, and every parameter above. A new
   `conformance/http/` directory whose cases run with the test server started and its base
   URL (`http://127.0.0.1:<port>`) as `Program.arguments[0]`, documented in
   `conformance/README.md` beside `color/` and `local-zone/`. Cases for each request form,
   each response member, `strict` both ways, and every row of the errors table the local
   server can produce.

   **Settled while building (2026-09-27):** `std.http.Client.fetch` does not retain response
   metadata, so the transport uses its lower-level `request` flow to copy the final address,
   reason phrase, and received headers before streaming the body. The interpreter owns one
   transport client for its whole run and transfers a completed body into Emerald's existing
   immutable `Bytes` storage. `conformance/http/` starts the same loopback server as the Zig
   tests for each case and passes only its generated base address as `Program.arguments[0]`.
3. **The real internet, checked by hand.** An opt-in `zig build http-live` (never part of
   `zig build test` or CI) that fetches a few real HTTPS addresses, including badssl.com's
   expired, self-signed, and wrong-host certificates, and checks each message; plus unknown
   host and proxy behavior. Record the run in the journal. Fix whatever it finds.
4. **Documentation and integration.** `docs/library/http.md`, an inventory row, an example,
   a new rewrite-context section (15.10) with decision rows in 22, and 15.7 updated. The
   example needs a network, so check how `tools/check-doc-examples.sh` runs linked examples
   and keep that check passing offline (for example, an example that reads the server
   address from its arguments and says so when none is given). Then remove this plan, as
   the date, regex, and JSON plans were removed, and point any references at 15.10.

## Working notes for the executor

These come from reviewing the previous two milestones.

- **Never reach the internet from `zig build test`.** Everything automatic runs against the
  local server. CI runs on Ubuntu, macOS, and Windows, so the server must work on all three:
  bind `127.0.0.1` with port 0 and read back the port.
- **Model the plumbing on JSON's.** `Interpreter.callJson`, `JsonBuilder`, and the
  `Json` prelude struct are the closest pattern: a prelude struct with private fields, built
  natively, and positional natives behind named Emerald functions.
- **Bind arguments by name, never by position.** The JSON review found `Json.decode(as:,
  text:)` crashing because the interpreter read `arguments[0]`. Use `evaluateBound` (or the
  checker's binding) for every native that takes named arguments.
- **Test every branch of behavior, not only the happy path.** The JSON review found field
  defaults silently overwriting decoded data; only a case where the document gave the value
  would have caught it. For each parameter, test it given, omitted, and wrong.
- **Check every example's output against the built binary** before writing it into docs or
  expectations.
- **Write a commit message body** for each slice: what it adds, what was settled, and the
  validation run. The JSON slices' commits had none, which made them slow to review.
- **Errors are part of the feature.** Match the errors table; a failure that surfaces as a
  Zig error name (`error.ConnectionRefused`) or a crash is a bug.
- **Do not expose sockets, connections, or clients** as Emerald types; they are out of
  scope (below).
- **Keep AGENTS.md's handoff rule:** update docs/handoff.md before each commit, and do not
  push unless the user says so.

## Out of scope for this milestone

Sockets (`TcpSocket`, `TcpServer`, `UdpSocket`), an HTTP server, WebSockets, HTTP/2, streaming
request or response bodies, cookies and sessions, multipart form uploads, authentication
helpers beyond writing an `Authorization` header, character sets other than UTF-8, a `Url`
type, and asynchronous or concurrent requests. Sockets and servers belong with concurrency,
since a server that serves one client at a time is of little use; the rest can be revisited
with a real program that needs it (24).

## Risks

- **Timeouts on a single-threaded `Io`.** If `global_single_threaded` cannot race a request
  against a timer, the fallbacks, in order: run each request on an `Io.Threaded` instance
  with worker threads; or set socket-level timeouts (`SO_RCVTIMEO`/`SO_SNDTIMEO`, and their
  Windows equivalents) on the connection plus `connectTcpOptions`'s connect timeout. Decide
  in slice 1 and record why; do not ship a request that can hang forever.
- **Certificates on machines without a usable system store.** Some minimal Linux containers
  have no root certificates. `rescan` then fails, and the message should say that the
  machine has no trusted certificates, rather than blaming the server.
- **DNS in tests.** Resolving a name depends on the machine's network, so the unknown-host
  message is tested by mapping the Zig error in a unit test, and live only in slice 3.
- **Startup.** Every run type-checks the whole prelude (a ReleaseSafe `print(1)` is about
  9.3 ms). Keep the prelude additions lean, and measure. The startup work is queued right
  after this milestone.
