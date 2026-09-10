var count: Int = 100

func check(): String {
    var count = 1
    return "local #{count}, module #{Shadow.count}"
}
