# Section 12: mistakes in a choice's data are reported one choice at a time.
enum Download {
    finished(path)
    waiting()
    failed(message: String = "unknown")
    done
}
