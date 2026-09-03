print("--- Miles to Kilometers Calculator ---")

var miles = read_line("Enter the distance in miles: ").to_float()
print("#{miles}mi is equivalent to #{(miles * 1.609).round}km")