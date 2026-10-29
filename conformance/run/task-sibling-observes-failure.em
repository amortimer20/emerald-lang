# Only the group's owner observing a failing child's result keeps the group
# from raising it (15.13). A sibling reading it in cleanup does not.
try {
    Tasks.run { tasks =>
        const failing = tasks.start { =>
            Tasks.yield()
            raise AssertionError("child failed")
        }
        tasks.start { =>
            try {
                Program.sleep(Duration(seconds: 30))
            }
            finally {
                try {
                    failing.result()
                }
                catch error: AssertionError {
                    print("sibling observed: #{error.message}")
                }
            }
        }
    }
    print("unexpected: group returned normally")
}
catch error: AssertionError {
    print("group raised: #{error.message}")
}
