var module_count = 1

Tasks.run { tasks =>
    tasks.start { => print(module_count) }
}

func check_local() {
    var local_count = 2
    Tasks.run { tasks =>
        tasks.start { =>
            const nested = { => print(local_count) }
            nested()
        }
    }
}

check_local()
