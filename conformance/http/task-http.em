class Progress {
    var happened: Bool = false
}
const progress = Progress()
const base = Program.arguments[0]
Tasks.run { tasks =>
    const request = tasks.start { =>
        const response = Http.get("#{base}/ok")
        assert(progress.happened)
        return response.text
    }
    tasks.start { => progress.happened = true }
    const response = request.result()
    print(progress.happened)
    print(response)
}
