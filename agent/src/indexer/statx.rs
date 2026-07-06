use libc::{c_char, c_int, c_uint};
use std::sync::atomic::{AtomicBool, Ordering};

pub const STATX_TYPE: u32 = 0x0001;
pub const STATX_INO: u32 = 0x0100;
pub const STATX_SIZE: u32 = 0x0200;
pub const STATX_MTIME: u32 = 0x0040;
pub const STATX_BTIME: u32 = 0x0800;

/// Whether the statx(2) syscall is available on this kernel.
/// Set to false on first ENOSYS; subsequent calls skip straight to lstat.
static STATX_AVAILABLE: AtomicBool = AtomicBool::new(true);

/// Normalised result from either statx(2) or lstat(2).
pub struct StatResult {
    pub mode: u32,
    pub ino: u64,
    pub size: u64,
    pub dev: u64,
    pub mtime_sec: i64,
    pub mtime_nsec: u32,
    /// Birth time  - Some when available (statx on a filesystem that reports it),
    /// None when unavailable (lstat fallback or filesystem that doesn't track it).
    pub btime: Option<(i64, u32)>,
}

/// Call statx(2) with AT_SYMLINK_NOFOLLOW; on ENOSYS fall back to lstat(2).
/// This is the only entry point callers should use.
pub fn stat_file(path: *const c_char) -> std::io::Result<StatResult> {
    if STATX_AVAILABLE.load(Ordering::Relaxed) {
        let mask = STATX_SIZE | STATX_MTIME | STATX_BTIME | STATX_TYPE | STATX_INO;
        match statx(libc::AT_FDCWD, path, libc::AT_SYMLINK_NOFOLLOW, mask) {
            Ok(stx) => {
                return Ok(StatResult {
                    mode: stx.stx_mode as u32,
                    ino: stx.stx_ino,
                    size: stx.stx_size,
                    dev: ((stx.stx_dev_major as u64) << 32) | (stx.stx_dev_minor as u64),
                    mtime_sec: stx.stx_mtime.tv_sec,
                    mtime_nsec: stx.stx_mtime.tv_nsec,
                    btime: if (stx.stx_mask & STATX_BTIME) != 0 {
                        Some((stx.stx_btime.tv_sec, stx.stx_btime.tv_nsec))
                    } else {
                        None
                    },
                });
            }
            Err(e) if e.raw_os_error() == Some(libc::ENOSYS) => {
                STATX_AVAILABLE.store(false, Ordering::Relaxed);
                // fall through to lstat below
            }
            Err(e) => return Err(e),
        }
    }
    lstat_fallback(path)
}

fn lstat_fallback(path: *const c_char) -> std::io::Result<StatResult> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::lstat(path, &mut st) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(StatResult {
        mode: st.st_mode as u32,
        ino: st.st_ino,
        size: st.st_size as u64,
        dev: st.st_dev as u64,
        mtime_sec: st.st_mtime,
        mtime_nsec: st.st_mtime_nsec as u32,
        btime: None,
    })
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StatxTimestamp {
    pub tv_sec: i64,
    pub tv_nsec: u32,
    __reserved: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Statx {
    pub stx_mask: u32,
    pub stx_blksize: u32,
    pub stx_attributes: u64,
    pub stx_nlink: u32,
    pub stx_uid: u32,
    pub stx_gid: u32,
    pub stx_mode: u16,
    __spare0: u16,
    pub stx_ino: u64,
    pub stx_size: u64,
    pub stx_blocks: u64,
    pub stx_attributes_mask: u64,
    pub stx_atime: StatxTimestamp,
    pub stx_btime: StatxTimestamp,
    pub stx_ctime: StatxTimestamp,
    pub stx_mtime: StatxTimestamp,
    pub stx_rdev_major: u32,
    pub stx_rdev_minor: u32,
    pub stx_dev_major: u32,
    pub stx_dev_minor: u32,
    pub stx_mnt_id: u64,
    pub stx_dio_mem_align: u32,
    pub stx_dio_offset_align: u32,
    __spare3: [u64; 12],
}

pub fn statx(dirfd: c_int, path: *const c_char, flags: c_int, mask: u32) -> std::io::Result<Statx> {
    let mut stx = Statx::default();
    let rc = unsafe {
        libc::syscall(
            libc::SYS_statx,
            dirfd,
            path,
            flags,
            mask as c_uint,
            &mut stx as *mut Statx,
        )
    };
    if rc == 0 {
        Ok(stx)
    } else {
        Err(std::io::Error::last_os_error())
    }
}
