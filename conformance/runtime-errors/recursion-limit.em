# Section 7.2: at least 1,000 active calls are supported, and crossing the limit
# raises rather than exhausting the host stack. Repeated frames are summarized.

func forever(n: Int): Int {
    return forever(n + 1)
}

print(forever(0))
