Tasks.run { tasks =>
    const first = tasks.start { => 10 }
    const second = tasks.start { => 20 }
    print(first.done?())
    print(first.type_name)
    print(first.result())
    print(second.result())
    print(first.done?())
    const quiet = tasks.start { => print("quiet") }
    quiet.result()
}
