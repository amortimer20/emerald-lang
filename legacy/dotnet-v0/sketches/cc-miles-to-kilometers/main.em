print("--- Miles to Kilometers Calculator ---")

var miles = read_line("Enter the distance in miles: ").to_float()
var km = miles * 1.609
print("#{miles}mi is equivalent to #{km.round_to(2)}km")