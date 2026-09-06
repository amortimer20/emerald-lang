# A file may hold an enum and functions both. The functions still become the module.
enum Size { SMALL, LARGE }

func describe(size: Size): String {
    return size.name.lower()
}
