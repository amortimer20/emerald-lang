# exit() in cleanup while a failing group drains ends the program with that
# status; the group's earlier failure is not reported (15.2, 15.13).
Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            print("cleanup exits")
            exit(7)
        }
    }
    tasks.start { =>
        Tasks.yield()
        raise AssertionError("trigger")
    }
}
print("unexpected continuation")
