# A task cancelled before it ever runs never runs its block; its result
# raises CancelledError (15.13).
Tasks.run { tasks =>
    const queued = tasks.start { =>
        print("unexpected: queued task body ran")
        return 1
    }
    queued.cancel()
    try {
        print(queued.result())
    }
    catch error: CancelledError {
        print("queued: #{error.message}")
    }
    print(queued.done?())
}
print("finished")
