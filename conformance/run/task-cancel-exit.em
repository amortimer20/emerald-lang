Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 60))
        }
        finally {
            print("exit cleanup")
        }
    }
    Tasks.yield()
    exit()
}
print("unexpected continuation")
