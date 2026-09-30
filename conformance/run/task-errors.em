try {
    Tasks.run { tasks =>
        tasks.start { =>
            raise AssertionError("one task failed")
        }
    }
}
catch error: AssertionError {
    print(error.message)
}

try {
    Tasks.run { tasks =>
        tasks.start { =>
            raise AssertionError("first task failed")
        }
        tasks.start { =>
            raise AssertionError("second task failed")
        }
    }
}
catch error: AssertionError {
    print(error.message)
}

Tasks.run { tasks =>
    const failed = tasks.start { =>
        raise AssertionError("handled task failure")
    }
    try {
        failed.result()
    }
    catch error: AssertionError {
        print(error.message)
    }
}
