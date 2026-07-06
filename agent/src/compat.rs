// musl libc doesn't provide the glibc __*_chk hardened variants of memcpy/memmove/memset.
// Some C libraries linked into our musl static build call these symbols and fail to link
// without them. We provide trivial pass-through stubs  - the safety checks they normally
// do are not needed in this context (the callers are trusted compiled code, not user input).
use libc::c_void;

#[no_mangle]
pub unsafe extern "C" fn __memcpy_chk(
    dest: *mut c_void,
    src: *const c_void,
    len: usize,
    _dest_len: usize,
) -> *mut c_void {
    libc::memcpy(dest, src, len)
}

#[no_mangle]
pub unsafe extern "C" fn __memmove_chk(
    dest: *mut c_void,
    src: *const c_void,
    len: usize,
    _dest_len: usize,
) -> *mut c_void {
    libc::memmove(dest, src, len)
}

#[no_mangle]
pub unsafe extern "C" fn __memset_chk(
    dest: *mut c_void,
    value: libc::c_int,
    len: usize,
    _dest_len: usize,
) -> *mut c_void {
    libc::memset(dest, value, len)
}
