# The wide clause is written first, so nothing can reach the narrow one below it.
class NotFound extends Error { }

try {
    throw NotFound("gone")
}
catch e {
    print("anything: #{e.message}")
}
catch e: NotFound {
    print("never reached")
}
