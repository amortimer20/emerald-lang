# From outside it is unchanged: reached through the type it belongs to.
print(Text.shout("hi"))
print(Text.twice("ok"))
print(Text.used_so_far())

# And a local of the same name still wins over the module's own.
print(Shadow.check())
