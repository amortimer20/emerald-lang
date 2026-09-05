## §3.3 lowers a module file's top-level code to a static constructor: it runs once, on
## first member access. It used to run nowhere at all — the statements were handed through
## as class "members", and every pass that walked members skipped anything that was not a
## declaration. Code you had written never executed and nothing said so.
print("entry starts")
print(Counter.total)
print(Counter.total)
print("untouched is never initialised")
print("entry ends")
