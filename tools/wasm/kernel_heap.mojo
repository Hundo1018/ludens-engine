"""wasm leaf-kernel probe (ROADMAP 17.76), the negative control: a kernel
that allocates (a List) must report runtime imports."""


@export
def ludens_kernel_heap_sum(n: Int32) abi("C") -> Int32:
    var xs = List[Int32]()
    for i in range(Int(n)):
        xs.append(Int32(i))
    var t = Int32(0)
    for x in xs:
        t += x
    return t


def main():
    pass
