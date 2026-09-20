try {
    File.read("missing-file-for-file-error-catch.txt")
}
catch error: FileError {
    print(error.message)
}
