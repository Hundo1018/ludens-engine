from std.reflection import reflect

def same[A: AnyType, B: AnyType]() -> Bool:
    comptime a = reflect[A].name[qualified_builtins=True]()
    comptime b = reflect[B].name[qualified_builtins=True]()
    comptime if a == b:
        return True
    else:
        return False

def main():
    print("Int,Int=", same[Int, Int]())
    print("Int,Int64=", same[Int, Int64]())
    print("List[Int],List[Float32]=", same[List[Int], List[Float32]]())
    print("name=", reflect[List[Int]].name[qualified_builtins=True]())
