class FirstError extends Error {
}

class CleanupError extends Error {
}

try {
    raise FirstError("work failed")
}
finally {
    raise CleanupError("cleanup failed")
}
