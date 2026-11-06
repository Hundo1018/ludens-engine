"""Platform services: the os_* imports the JS host (shell/web/os_host.mjs) provides; declared in wasm.toml `host_imports`.

Results of the asynchronous calls arrive through `os_poll`, inside a frame; nothing calls back into wasm. See the host
file for the packet layout and the paths a game may use."""
from std.ffi import external_call


def os_clipboard_write(ptr: UInt64, length: UInt64) -> Int32:
    return external_call["os_clipboard_write", Int32](ptr, length)


def os_clipboard_read_request() -> Int32:
    return external_call["os_clipboard_read_request", Int32]()


def os_file_write(path_ptr: UInt64, path_len: UInt64, data_ptr: UInt64, data_len: UInt64) -> Int32:
    return external_call["os_file_write", Int32](path_ptr, path_len, data_ptr, data_len)


def os_file_read_request(id: Int32, path_ptr: UInt64, path_len: UInt64) -> Int32:
    return external_call["os_file_read_request", Int32](id, path_ptr, path_len)


def os_poll(buf: UInt64, cap: UInt64) -> Int64:
    return external_call["os_poll", Int64](buf, cap)
