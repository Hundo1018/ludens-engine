from std.ffi import _Global

def _zero() -> Int:
    return 0

comptime Counter = _Global["ludens.counter", _zero]

@export
def bump() abi("C") -> Int:
    try:
        var p = Counter.get_or_create_ptr()
        p[] += 100
        return p[]
    except:
        return -1
