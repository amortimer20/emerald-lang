const base = Program.arguments[0]
Tasks.run { tasks =>
    const request = tasks.start { =>
        try {
            return Http.get("#{base}/slow", timeout: Duration(seconds: 60)).text
        }
        finally {
            print("request cleanup")
        }
    }
    Tasks.yield()
    request.cancel()
    try {
        request.result()
    }
    catch error: CancelledError {
        print("request cancelled")
    }
}
print(Http.get("#{base}/ok").text)
try {
    Tasks.run { tasks =>
        tasks.start { =>
            raise RuntimeError("first HTTP failure")
        }
        try {
            Http.get("#{base}/slow", timeout: Duration(seconds: 60))
        }
        finally {
            print("owner request cleanup")
        }
    }
}
catch error: RuntimeError {
    print(error.message)
}
print(Http.get("#{base}/ok").text)
