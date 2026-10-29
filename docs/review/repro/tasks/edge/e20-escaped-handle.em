class Holder {
    var group: TaskGroup? = nothing
}
const holder = Holder()
const handle = Tasks.run { tasks =>
    holder.group = tasks
    return tasks.start { => 11 }
}
print(handle.result())
print(handle.done?())
const group = holder.group
if group != nothing {
    try {
        group.start { => 1 }
    }
    catch error: RuntimeError {
        print(error.message)
    }
}
