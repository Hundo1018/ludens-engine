from std.ffi import external_call

def main():
    # Same C symbol, two argument lists: (Int32) and (Int64).
    var a = external_call["abs", Int32](Int32(-3))
    var b = external_call["abs", Int32](Int64(-4))
    print(a, b)
