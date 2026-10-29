# A sibling (not the group's owner) observes the failing child's result in its cleanup.
# 15.13: only an *owner* catching the failure keeps the group from raising it.
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
    print("group returned normally")
}
catch error: AssertionError {
    print("group raised: #{error.message}")
}
