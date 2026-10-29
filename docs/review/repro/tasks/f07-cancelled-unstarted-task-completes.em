# Cancel a task before it ever ran.
Tasks.run { tasks =>
    const queued = tasks.start { =>
        print("queued task body ran")
        return 1
    }
    queued.cancel()
    print(queued.done?())
    try {
        print(queued.result())
    }
    catch error: CancelledError {
        print("queued: #{error.message}")
    }
}
print("finished")
