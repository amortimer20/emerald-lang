# exit stops the program; a nonzero code reports failure
print("checking...")

var bad = false
if bad {
    print("cannot continue")
    exit(1)
}

print("all good")
exit()
print("this line never runs")
