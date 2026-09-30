"""Does -O0 build a shared library faster than -O3? Stdlib only, so it runs
on any Mojo version (docs/upstream/o0-build-time.md). Exports that
instantiate common generic code: List, Dict, String formatting, sort.

    mojo build --emit shared-lib [-O0] probe_o0_cost.mojo -o p.so
"""


@export
def p_list(n: Int) abi("C") -> Int:
    var xs = List[Int]()
    for i in range(n):
        xs.append((i * 7919) % 104729)
    sort(xs)
    var t = 0
    for x in xs:
        t += x
    return t


@export
def p_dict(n: Int) abi("C") -> Int:
    var d = Dict[String, Int]()
    for i in range(n):
        d[String(i)] = i * i
    var t = 0
    for e in d.items():
        t += e.value + e.key.byte_length()
    return t


@export
def p_string(n: Int) abi("C") -> Int:
    var s = String()
    for i in range(n):
        s += String(i) + ","
    var parts = s.split(",")
    return len(parts) + s.byte_length()


@export
def p_float(n: Int) abi("C") -> Float64:
    var xs = List[Float64]()
    for i in range(n):
        xs.append(Float64(i) * 0.5)
    var t: Float64 = 0
    for x in xs:
        t += x * x
    return t
