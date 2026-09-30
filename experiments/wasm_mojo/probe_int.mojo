"""W1 probe step 1: pure integer code, no allocation."""


@export
def add(a: Int32, b: Int32) abi("C") -> Int32:
    return a + b


@export
def sum_to(n: Int32) abi("C") -> Int32:
    var s: Int32 = 0
    for i in range(n):
        s += Int32(i)
    return s
