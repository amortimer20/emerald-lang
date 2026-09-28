const base = Program.arguments[0]

const get = Http.get("#{base}/ok", query: ["city": "São Paulo"])
print(get.status)
print(get.reason)
print(get.ok?())
print(get.text)
print(get.bytes.count)
print(get.url.contains?("city=S%C3%A3o%20Paulo"))

const redirected = Http.get("#{base}/redirect")
print(redirected.url.ends_with?("/ok"))

const headers = Http.get("#{base}/headers")
print(headers.header("X-Answer"))
print(headers.headers["set-cookie"] == "one=1\ntwo=2")

print(Http.post("#{base}/echo", body: "text", headers: ["x-test": "yes"]).text)
print(Http.put("#{base}/echo", json: "{}", headers: ["x-test": "yes"]).text)
print(Http.patch("#{base}/echo", bytes: Bytes.from_list([1, 2]), headers: ["x-test": "yes"]).bytes.count)
print(Http.delete("#{base}/ok").status)

const missing = Http.get("#{base}/missing", strict: false)
print(missing.status)
print(not missing.ok?())
print(Http.get("#{base}/json").json().get("answer").int())
print(Http.encode_component("São Paulo/a?b"))
