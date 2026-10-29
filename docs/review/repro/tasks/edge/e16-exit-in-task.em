Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            print("sleeper cleanup")
        }
    }
    tasks.start { =>
        print("about to exit")
        exit(3)
    }
    try {
        Program.sleep(Duration(seconds: 30))
    }
    finally {
        print("main cleanup")
    }
}
print("unexpected continuation")
