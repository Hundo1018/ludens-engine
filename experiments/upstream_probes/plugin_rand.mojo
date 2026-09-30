from std.random import random_ui64, seed

@export
def roll() abi("C") -> Int:
    seed(7)
    return Int(random_ui64(0, 1000))
