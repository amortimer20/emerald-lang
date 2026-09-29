Tasks.run { tasks =>
    tasks.start { =>
        Program.sleep(Duration(milliseconds: 5))
        print("first")
    }
    tasks.start { =>
        Program.sleep(Duration(milliseconds: 25))
        print("second")
    }
    tasks.start { =>
        Program.sleep(Duration(milliseconds: 50))
        print("third")
    }
}
