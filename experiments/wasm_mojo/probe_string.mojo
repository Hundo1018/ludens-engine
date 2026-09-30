"""W2 probe: does a short `String` survive the retarget?

schema field names ("capacity", "frame", "box_x") came out of a wasm
snapshot cut to 4 bytes. Each export builds a String one way and returns
its byte length; natively every one of them is the length of the text.
"""


@export
def literal_len() abi("C") -> Int32:
    var s = String("capacity")
    return Int32(s.byte_length())


@export
def concat_len() abi("C") -> Int32:
    var s = String("") + String("capacity")
    return Int32(s.byte_length())


@export
def materialized_len() abi("C") -> Int32:
    comptime NAME: StaticString = "capacity"
    var s = String(materialize[NAME]())
    return Int32(s.byte_length())


@export
def long_len() abi("C") -> Int32:
    var s = String("a string longer than twenty-three bytes")
    return Int32(s.byte_length())


@export
def as_bytes_len() abi("C") -> Int32:
    var s = String("capacity")
    return Int32(len(s.as_bytes()))
