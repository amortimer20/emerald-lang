# strings.split: `try pieces.append(gpa, try gpa.dupe(...))` leaks the
# duplicated piece when the append itself fails.
print("a,b,c,d,e,f,g,h,i".split(","))
