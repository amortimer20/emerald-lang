# Clearly different sleep lengths resume in deadline order; equal requested lengths
# started in sequence have increasing deadlines.
Tasks.run { tasks =>
    for ms in [90, 10, 50, 30, 70] {
        tasks.start { =>
            Program.sleep(Duration(milliseconds: ms))
            print("slept #{ms}")
        }
    }
    for i in 0..<5 {
        tasks.start { =>
            Program.sleep(Duration(milliseconds: 1))
            print("equal #{i}")
        }
    }
}
