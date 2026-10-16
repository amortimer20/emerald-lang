enum Download {
    waiting
    finished(path: String)
}

const download = Download.waiting
case download {
    when Download.finished(saved) {
        print(sa/*cursor*/)
    }
    else {
    }
}
