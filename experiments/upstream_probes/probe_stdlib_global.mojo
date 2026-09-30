from std.ffi import _Global

def _zero() -> Int:
    return 0

comptime Counter = _Global["ludens.counter", _zero]

def bump() raises -> Int:
    var p = Counter.get_or_create_ptr()
    p[] += 1
    return p[]

def main() raises:
    _ = bump()
    _ = bump()
    print("global_counter_after_3=", bump())
