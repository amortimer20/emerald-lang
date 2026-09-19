# The same for a file's own bindings while the file is being set up (14.1).
struct Log {
    var lines: List[String]

    func add(text: String) {
        self.lines.append(text)
        peek()
    }
}

var log = Log([])

func peek() {
    print(log.lines.count)
}

var ready = start()

func start(): Bool {
    log.add("started")
    return true
}
