//! zygote_exec17: starts the guest zygote for Android 17 (SDK 37+) images.
//!
//! The original assets/zygote_exec has the LineageOS 23.2 (Android 16) class
//! paths compiled in. This launcher does the same job but takes
//! BOOTCLASSPATH, DEX2OATBOOTCLASSPATH, SYSTEMSERVERCLASSPATH and
//! STANDALONE_SYSTEMSERVER_JARS from its environment, so master_inner.sh can
//! fill them from the guest image's own derive_classpath.
//!
//! It takes the role init normally plays for zygote:
//!   * creates the listening sockets /dev/socket/zygote and
//!     /dev/socket/usap_pool_primary (0660 root:system, like init.zygote64.rc)
//!   * hands them over as fds 3 and 4 (ANDROID_SOCKET_zygote=3,
//!     ANDROID_SOCKET_usap_pool_primary=4)
//!   * points stdin/stdout/stderr at /dev/null: zygote aborts on fds it
//!     does not know about, such as an open log file
//!   * execs /system/bin/app_process64 as "zygote64"
//!
//! Build: cargo build --release --target aarch64-unknown-linux-musl

use std::ffi::c_int;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::{AsRawFd, IntoRawFd};
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::process::Command;

extern "C" {
    fn dup2(old: c_int, new: c_int) -> c_int;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
}

const F_DUPFD: c_int = 0;
const F_SETFD: c_int = 2;
const AID_SYSTEM: u32 = 1000;
const LOG: &str = "/data/zygote_exec17.log";

const CLASSPATH_VARS: [&str; 4] = [
    "BOOTCLASSPATH",
    "DEX2OATBOOTCLASSPATH",
    "SYSTEMSERVERCLASSPATH",
    "STANDALONE_SYSTEMSERVER_JARS",
];

const FIXED_ENV: [(&str, &str); 12] = [
    ("PATH", "/system/bin:/system/xbin"),
    ("ANDROID_ROOT", "/system"),
    ("ANDROID_DATA", "/data"),
    ("ANDROID_STORAGE", "/storage"),
    ("ANDROID_ART_ROOT", "/apex/com.android.art"),
    ("ANDROID_I18N_ROOT", "/apex/com.android.i18n"),
    ("ANDROID_TZDATA_ROOT", "/apex/com.android.tzdata"),
    ("EXTERNAL_STORAGE", "/sdcard"),
    ("ASEC_MOUNTPOINT", "/mnt/asec"),
    ("ANDROID_ASSETS", "/system/app"),
    ("ANDROID_SOCKET_zygote", "3"),
    ("ANDROID_SOCKET_usap_pool_primary", "4"),
];

fn log(msg: &str) {
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(LOG) {
        let _ = writeln!(f, "{msg}");
    }
}

fn fail(msg: &str) -> ! {
    log(&format!("zygote_exec17: {msg}"));
    std::process::exit(1);
}

/// Listening unix socket at `path`, 0660 root:system, moved to a high fd so
/// it cannot collide with 0-4 before the final dup2.
fn listen(path: &str) -> c_int {
    let _ = fs::remove_file(path);
    let l = UnixListener::bind(path).unwrap_or_else(|e| fail(&format!("bind {path}: {e}")));
    let _ = std::os::unix::fs::chown(path, Some(0), Some(AID_SYSTEM));
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o660));
    let fd = l.into_raw_fd();
    let high = unsafe { fcntl(fd, F_DUPFD, 64 as c_int) };
    if high < 0 {
        fail(&format!("dup {path}"));
    }
    high
}

/// Place `fd` at `target` without close-on-exec.
fn place(fd: c_int, target: c_int) {
    if unsafe { dup2(fd, target) } != target || unsafe { fcntl(target, F_SETFD, 0 as c_int) } < 0 {
        fail(&format!("dup2 to {target}"));
    }
}

fn main() {
    let mut env: Vec<(String, String)> = Vec::new();
    for name in CLASSPATH_VARS {
        match std::env::var(name) {
            Ok(v) if !v.is_empty() => env.push((name.to_string(), v)),
            _ => fail(&format!("{name} not set (run derive_classpath first)")),
        }
    }
    for (k, v) in FIXED_ENV {
        env.push((k.to_string(), v.to_string()));
    }

    let zygote = listen("/dev/socket/zygote");
    let usap = listen("/dev/socket/usap_pool_primary");

    let null = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/null")
        .unwrap_or_else(|e| fail(&format!("/dev/null: {e}")));
    let nfd = null.as_raw_fd();
    log("zygote_exec17: sockets ready, exec app_process64");
    for t in 0..3 {
        place(nfd, t);
    }
    place(zygote, 3);
    place(usap, 4);

    let err = Command::new("/system/bin/app_process64")
        .arg0("zygote64")
        .args([
            "-Xzygote",
            "-Xforcejitzygote",
            "/system/bin",
            "--zygote",
            "--start-system-server",
            "--socket-name=zygote",
        ])
        .env_clear()
        .envs(env)
        .exec();
    fail(&format!("exec app_process64: {err}"));
}
