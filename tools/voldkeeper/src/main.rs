//! voldkeeper: keeps One UI's vold registered under the binder name "vold".
//!
//! Lineage shares One UI's servicemanager. Its own vold registers "vold"
//! there too, replacing One UI's entry. When return_to_oneui.sh kills it,
//! nothing is registered as "vold" any more, although One UI's vold is still
//! running, and One UI's restarted system_server cannot commit the userdata
//! checkpoint: the phone reboots with "reboot,checkpoint_commit_failed"
//! (seen on an S26 Ultra after a LineageOS 24 session).
//!
//! Using One UI's vold from Lineage instead is not an option: the IVold
//! transaction numbers differ, so Lineage's calls land on other vold methods
//! (supportsCheckpoint came back as a NullPointerException).
//!
//!   voldkeeper hold <stage>   run before Lineage starts: takes a reference to
//!                             One UI's vold binder, then waits. When
//!                             <stage>/vold_restore appears it registers that
//!                             binder as "vold" again, checks that the name
//!                             points to it, writes <stage>/vold_keeper.state
//!                             and exits.
//!   voldkeeper check          print what "vold" points to now (read-only).
//!
//! It talks to the binder driver directly (static musl binary, no libbinder).
//! Build: cargo build --release --target aarch64-unknown-linux-musl

use std::ffi::{c_int, c_void};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

extern "C" {
    fn ioctl(fd: c_int, req: c_int, ...) -> c_int;
    fn mmap(addr: *mut c_void, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64)
        -> *mut c_void;
}

const BINDER_WRITE_READ: u32 = 0xc030_6201;
const BINDER_VERSION: u32 = 0xc004_6209;

const BC_TRANSACTION: u32 = 0x4040_6300;
const BC_FREE_BUFFER: u32 = 0x4008_6303;
const BC_INCREFS: u32 = 0x4004_6304;
const BC_ACQUIRE: u32 = 0x4004_6305;

const BR_ERROR: u32 = 0x8004_7200;
const BR_REPLY: u32 = 0x8040_7203;
const BR_DEAD_REPLY: u32 = 0x7205;
const BR_FAILED_REPLY: u32 = 0x7211;
const BR_FROZEN_REPLY: u32 = 0x7212;

const TF_STATUS_CODE: u32 = 0x08;
const TF_ACCEPT_FDS: u32 = 0x10;
const BINDER_TYPE_HANDLE: u32 = 0x7368_2a85;
const PING_TRANSACTION: u32 = 0x5f50_4e47;

// android.os.IServiceManager (checked with `service call manager N s16 vold`
// on Android 17: 1 getService, 2 getService2, 3 checkService, 4 checkService2).
const SM_DESCRIPTOR: &str = "android.os.IServiceManager";
const SM_CHECK_SERVICE: u32 = 3;
const SM_ADD_SERVICE: u32 = 5;
const DUMP_FLAG_PRIORITY_DEFAULT: i32 = 1 << 3;
const PARCEL_HEADER_SYST: i32 = 0x5359_5354;

const MAP_SIZE: usize = 1 << 20;

#[repr(C)]
#[derive(Default)]
struct WriteRead {
    write_size: u64,
    write_consumed: u64,
    write_buffer: u64,
    read_size: u64,
    read_consumed: u64,
    read_buffer: u64,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct TxData {
    target: u64,
    cookie: u64,
    code: u32,
    flags: u32,
    sender_pid: i32,
    sender_euid: u32,
    data_size: u64,
    offsets_size: u64,
    buffer: u64,
    offsets: u64,
}

struct Reply {
    data: Vec<u8>,
    offsets: Vec<u64>,
    buffer: u64,
    status_code: bool,
}

struct Binder {
    _file: fs::File,
    fd: c_int,
}

fn push_u32(v: &mut Vec<u8>, x: u32) {
    v.extend_from_slice(&x.to_le_bytes());
}

fn push_u64(v: &mut Vec<u8>, x: u64) {
    v.extend_from_slice(&x.to_le_bytes());
}

fn rd_u32(d: &[u8], at: usize) -> Option<u32> {
    d.get(at..at + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn rd_u64(d: &[u8], at: usize) -> Option<u64> {
    d.get(at..at + 8).map(|b| {
        let mut a = [0u8; 8];
        a.copy_from_slice(b);
        u64::from_le_bytes(a)
    })
}

impl Binder {
    fn open() -> Result<Binder, String> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/binder")
            .map_err(|e| format!("open /dev/binder: {e}"))?;
        let fd = file.as_raw_fd();
        let mut version: i32 = 0;
        if unsafe { ioctl(fd, BINDER_VERSION as c_int, &mut version as *mut i32) } < 0 {
            return Err("BINDER_VERSION failed".into());
        }
        if version != 8 {
            return Err(format!("unexpected binder protocol version {version}"));
        }
        let m = unsafe { mmap(std::ptr::null_mut(), MAP_SIZE, 1, 0x2 | 0x4000, fd, 0) };
        if m as isize == -1 {
            return Err("mmap /dev/binder failed".into());
        }
        Ok(Binder { _file: file, fd })
    }

    fn write_read(&self, write: &[u8], read: &mut [u8]) -> Result<usize, String> {
        let mut bwr = WriteRead {
            write_size: write.len() as u64,
            write_buffer: write.as_ptr() as u64,
            read_size: read.len() as u64,
            read_buffer: read.as_mut_ptr() as u64,
            ..Default::default()
        };
        loop {
            let r = unsafe { ioctl(self.fd, BINDER_WRITE_READ as c_int, &mut bwr as *mut WriteRead) };
            if r >= 0 {
                return Ok(bwr.read_consumed as usize);
            }
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() != Some(4) {
                return Err(format!("BINDER_WRITE_READ: {err}"));
            }
            // EINTR: retry whatever is left.
            bwr.write_size -= bwr.write_consumed.min(bwr.write_size);
            bwr.write_buffer += bwr.write_consumed;
            bwr.write_consumed = 0;
        }
    }

    fn write(&self, cmds: &[u8]) -> Result<(), String> {
        self.write_read(cmds, &mut []).map(|_| ())
    }

    fn transact(&self, handle: u32, code: u32, data: &[u8], offsets: &[u64]) -> Result<Reply, String> {
        let tx = TxData {
            target: handle as u64,
            code,
            flags: TF_ACCEPT_FDS,
            data_size: data.len() as u64,
            offsets_size: (offsets.len() * 8) as u64,
            buffer: data.as_ptr() as u64,
            offsets: offsets.as_ptr() as u64,
            ..Default::default()
        };
        let mut cmd = Vec::with_capacity(4 + 64);
        push_u32(&mut cmd, BC_TRANSACTION);
        let txb: [u8; 64] = unsafe { std::mem::transmute(tx) };
        cmd.extend_from_slice(&txb);

        let mut first = true;
        loop {
            let mut rbuf = [0u8; 512];
            let n = if first {
                first = false;
                self.write_read(&cmd, &mut rbuf)?
            } else {
                self.write_read(&[], &mut rbuf)?
            };
            let mut at = 0;
            while at + 4 <= n {
                let br = rd_u32(&rbuf, at).unwrap();
                at += 4;
                let size = ((br >> 16) & 0x3fff) as usize;
                match br {
                    BR_REPLY => {
                        let mut t = TxData::default();
                        let raw = &rbuf[at..at + 64];
                        unsafe {
                            std::ptr::copy_nonoverlapping(raw.as_ptr(), &mut t as *mut TxData as *mut u8, 64)
                        };
                        let d = unsafe { std::slice::from_raw_parts(t.buffer as *const u8, t.data_size as usize) };
                        let o = unsafe {
                            std::slice::from_raw_parts(t.offsets as *const u64, (t.offsets_size / 8) as usize)
                        };
                        return Ok(Reply {
                            data: d.to_vec(),
                            offsets: o.to_vec(),
                            buffer: t.buffer,
                            status_code: t.flags & TF_STATUS_CODE != 0,
                        });
                    }
                    BR_DEAD_REPLY => return Err("dead reply (target binder is gone)".into()),
                    BR_FAILED_REPLY => return Err("failed reply".into()),
                    BR_FROZEN_REPLY => return Err("frozen reply".into()),
                    BR_ERROR => {
                        return Err(format!("BR_ERROR {}", rd_u32(&rbuf, at).unwrap_or(0) as i32))
                    }
                    _ => at += size, // BR_NOOP, BR_TRANSACTION_COMPLETE, ...
                }
            }
        }
    }

    fn free(&self, buffer: u64) {
        let mut c = Vec::new();
        push_u32(&mut c, BC_FREE_BUFFER);
        push_u64(&mut c, buffer);
        let _ = self.write(&c);
    }

    fn acquire(&self, handle: u32) -> Result<(), String> {
        let mut c = Vec::new();
        push_u32(&mut c, BC_INCREFS);
        push_u32(&mut c, handle);
        push_u32(&mut c, BC_ACQUIRE);
        push_u32(&mut c, handle);
        self.write(&c)
    }

    fn ping(&self, handle: u32) -> Result<(), String> {
        let r = self.transact(handle, PING_TRANSACTION, &[], &[])?;
        self.free(r.buffer);
        if r.status_code {
            return Err(format!("ping status {}", rd_u32(&r.data, 0).unwrap_or(0) as i32));
        }
        Ok(())
    }
}

struct Parcel {
    data: Vec<u8>,
    offsets: Vec<u64>,
}

impl Parcel {
    fn new_call(descriptor: &str) -> Parcel {
        let mut p = Parcel { data: Vec::new(), offsets: Vec::new() };
        p.i32(0); // strict mode policy
        p.i32(-1); // work source: unset
        p.i32(PARCEL_HEADER_SYST);
        p.str16(descriptor);
        p
    }

    fn i32(&mut self, v: i32) {
        push_u32(&mut self.data, v as u32);
    }

    fn str16(&mut self, s: &str) {
        let u: Vec<u16> = s.encode_utf16().collect();
        self.i32(u.len() as i32);
        for c in u.iter().chain(std::iter::once(&0u16)) {
            self.data.extend_from_slice(&c.to_le_bytes());
        }
        while self.data.len() % 4 != 0 {
            self.data.push(0);
        }
    }

    fn handle(&mut self, handle: u32, stability: u32) {
        self.offsets.push(self.data.len() as u64);
        push_u32(&mut self.data, BINDER_TYPE_HANDLE);
        push_u32(&mut self.data, 0);
        push_u64(&mut self.data, handle as u64);
        push_u64(&mut self.data, 0);
        push_u32(&mut self.data, stability);
    }
}

fn exception(r: &Reply) -> Option<String> {
    if r.status_code {
        return Some(format!("status_t {}", rd_u32(&r.data, 0).unwrap_or(0) as i32));
    }
    let ex = rd_u32(&r.data, 0)? as i32;
    if ex == 0 {
        return None;
    }
    let len = rd_u32(&r.data, 4).unwrap_or(0) as usize;
    let msg: Vec<u16> = (0..len.min(200))
        .filter_map(|i| r.data.get(8 + 2 * i..10 + 2 * i).map(|b| u16::from_le_bytes([b[0], b[1]])))
        .collect();
    Some(format!("exception {ex}: {}", String::from_utf16_lossy(&msg)))
}

/// checkService(name): Some((handle, stability)) or None if nothing is
/// registered. Takes our own reference to the handle: freeing the reply
/// buffer drops the one the driver took for it, and the handle would be
/// invalid ("got transaction to invalid handle") from then on.
fn check_service(b: &Binder, name: &str) -> Result<Option<(u32, u32)>, String> {
    let mut p = Parcel::new_call(SM_DESCRIPTOR);
    p.str16(name);
    let r = b.transact(0, SM_CHECK_SERVICE, &p.data, &p.offsets)?;
    let result = (|| {
        if let Some(e) = exception(&r) {
            return Err(e);
        }
        let Some(&off) = r.offsets.first() else { return Ok(None) };
        let off = off as usize;
        if rd_u32(&r.data, off) != Some(BINDER_TYPE_HANDLE) {
            return Err("checkService reply is not a binder handle".into());
        }
        let handle = rd_u64(&r.data, off + 8).ok_or("short reply")? as u32;
        let stability = rd_u32(&r.data, off + 24).ok_or("short reply")?;
        b.acquire(handle)?;
        Ok(Some((handle, stability)))
    })();
    b.free(r.buffer);
    result
}

fn add_service(b: &Binder, name: &str, handle: u32, stability: u32) -> Result<(), String> {
    let mut p = Parcel::new_call(SM_DESCRIPTOR);
    p.str16(name);
    p.handle(handle, stability);
    p.i32(0); // allowIsolated = false (as vold's BinderService::publish)
    p.i32(DUMP_FLAG_PRIORITY_DEFAULT);
    let r = b.transact(0, SM_ADD_SERVICE, &p.data, &p.offsets)?;
    let e = exception(&r);
    b.free(r.buffer);
    match e {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn log(stage: &str, msg: &str) {
    let line = format!("{} voldkeeper[{}]: {msg}\n", now(), std::process::id());
    print!("{line}");
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(format!("{stage}/vold_keeper.log")) {
        let _ = f.write_all(line.as_bytes());
    }
}

fn set_state(stage: &str, state: &str) {
    let _ = fs::write(format!("{stage}/vold_keeper.state"), format!("{state}\n"));
}

fn restore(b: &Binder, handle: u32, stability: u32, stage: &str) -> Result<String, String> {
    b.ping(handle).map_err(|e| format!("One UI vold does not answer: {e}"))?;
    match check_service(b, "vold")? {
        // VOLDKEEPER_FORCE=1 re-registers anyway (a no-op for the phone,
        // used to test addService from One UI).
        Some((h, _)) if h == handle && std::env::var_os("VOLDKEEPER_FORCE").is_none() => {
            return Ok("already registered".into())
        }
        Some((h, _)) if h == handle => log(stage, "\"vold\" is already One UI's, re-registering anyway"),
        Some((h, _)) => {
            let other = if b.ping(h).is_ok() { "alive" } else { "dead" };
            log(stage, &format!("\"vold\" points to another binder (handle {h}, {other})"));
        }
        None => log(stage, "\"vold\" is not registered"),
    }
    add_service(b, "vold", handle, stability).map_err(|e| format!("addService: {e}"))?;
    match check_service(b, "vold")? {
        Some((h, _)) if h == handle => Ok("re-registered".into()),
        Some((h, _)) => Err(format!("after addService \"vold\" is handle {h}, not {handle}")),
        None => Err("after addService \"vold\" is still not registered".into()),
    }
}

fn hold(stage: &str) -> i32 {
    let trigger = format!("{stage}/vold_restore");
    let _ = fs::remove_file(&trigger);
    let b = match Binder::open() {
        Ok(b) => b,
        Err(e) => {
            log(stage, &e);
            set_state(stage, &format!("failed: {e}"));
            return 1;
        }
    };
    let (handle, stability) = match check_service(&b, "vold") {
        Ok(Some(x)) => x,
        Ok(None) => {
            log(stage, "\"vold\" is not registered, nothing to hold");
            set_state(stage, "failed: no vold");
            return 1;
        }
        Err(e) => {
            log(stage, &format!("checkService(vold): {e}"));
            set_state(stage, &format!("failed: {e}"));
            return 1;
        }
    };
    if let Err(e) = b.ping(handle) {
        log(stage, &format!("vold does not answer: {e}"));
        set_state(stage, &format!("failed: {e}"));
        return 1;
    }
    log(stage, &format!("holding One UI vold (handle {handle}, stability {stability:#x})"));
    set_state(stage, "held");
    loop {
        std::thread::sleep(Duration::from_millis(250));
        if !Path::new(&trigger).exists() {
            continue;
        }
        let _ = fs::remove_file(&trigger);
        return match restore(&b, handle, stability, stage) {
            Ok(how) => {
                log(stage, &format!("One UI vold is \"vold\" again ({how})"));
                set_state(stage, "restored");
                0
            }
            Err(e) => {
                log(stage, &format!("restore failed: {e}"));
                set_state(stage, &format!("restore failed: {e}"));
                1
            }
        };
    }
}

fn check() -> i32 {
    let b = match Binder::open() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    match check_service(&b, "vold") {
        Ok(Some((h, s))) => {
            let alive = match b.ping(h) { Ok(()) => "answers ping".to_string(), Err(e) => format!("ping failed: {e}") };
            println!("vold: handle {h}, stability {s:#x}, {alive}");
            0
        }
        Ok(None) => {
            println!("vold: not registered");
            2
        }
        Err(e) => {
            eprintln!("checkService(vold): {e}");
            1
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let code = match args.get(1).map(String::as_str) {
        Some("hold") if args.len() == 3 => hold(&args[2]),
        Some("check") => check(),
        _ => {
            eprintln!("usage: voldkeeper hold <stage-dir> | voldkeeper check");
            64
        }
    };
    std::process::exit(code);
}
