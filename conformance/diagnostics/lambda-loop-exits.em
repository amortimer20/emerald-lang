[1].each { x => break }
[1].each { x => continue }
while true {
    [1].each { x => break if x > 0 }
    [1].each { x => continue if x > 0 }
    break
}
