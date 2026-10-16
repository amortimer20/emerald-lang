enum Download {
    waiting
    finished(path: String)
}

const download = Download.waiting
const label = case download {
    when Download.finished(sa/*cursor*/ved) then saved
    when Download.waiting then ""
}
