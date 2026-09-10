# Every clause names an error this is not, so it keeps travelling and is reported
# against the line that threw it.
class NotFound extends Error { }

try {
    throw "plain trouble"
}
catch e: NotFound {
    print("never")
}
