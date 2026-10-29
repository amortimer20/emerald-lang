# exit(7) from a child's cleanup while its group drains after a failure.
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
