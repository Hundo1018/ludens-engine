def twice(x: Int) -> Int:
    return 2 * x

struct Holder:
    var f: def(Int) thin -> Int

    def __init__(out self, f: def(Int) thin -> Int):
        self.f = f

def main():
    var h = Holder(twice)
    print("thin_field_call=", h.f(21))
