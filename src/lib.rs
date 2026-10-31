//! Platform-independent core. The native adapter owns ScreenCaptureKit and calls
//! this API only on the main thread. Returned strings are owned by the caller.
use std::{
    ffi::{CStr, CString, c_char},
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

static NEXT_ID: AtomicU64 = AtomicU64::new(0);

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Settings {
    pub fps: u32,
    pub max_height: u32,
    pub countdown: u32,
    pub auto_stop_seconds: u32,
    pub system_audio: u32,
    pub microphone: u32,
    pub cursor: u32,
    pub clicks: u32,
    pub hide_app: u32,
    pub hevc: u32,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            fps: 30,
            max_height: 1080,
            countdown: 3,
            auto_stop_seconds: 0,
            system_audio: 1,
            microphone: 0,
            cursor: 1,
            clicks: 0,
            hide_app: 1,
            hevc: 0,
        }
    }
}
impl Settings {
    fn normalized(mut self) -> Self {
        if ![24, 30, 60].contains(&self.fps) {
            self.fps = 30;
        }
        if ![0, 1080, 1440, 2160].contains(&self.max_height) {
            self.max_height = 1080;
        }
        if ![0, 3, 5, 10].contains(&self.countdown) {
            self.countdown = 3;
        }
        self.auto_stop_seconds = self.auto_stop_seconds.min(86400);
        self.system_audio = u32::from(self.system_audio != 0);
        self.microphone = u32::from(self.microphone != 0);
        self.cursor = u32::from(self.cursor != 0);
        self.clicks = u32::from(self.clicks != 0);
        self.hide_app = u32::from(self.hide_app != 0);
        self.hevc = u32::from(self.hevc != 0);
        self
    }
    fn values(self) -> [u32; 10] {
        [
            self.fps,
            self.max_height,
            self.countdown,
            self.auto_stop_seconds,
            self.system_audio,
            self.microphone,
            self.cursor,
            self.clicks,
            self.hide_app,
            self.hevc,
        ]
    }
    fn encode(self) -> String {
        self.values()
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n"
    }
    fn decode(text: &str) -> Option<Self> {
        let v: Vec<u32> = text
            .lines()
            .map(str::parse)
            .collect::<Result<_, _>>()
            .ok()?;
        if v.len() != 10 {
            return None;
        }
        Some(
            Self {
                fps: v[0],
                max_height: v[1],
                countdown: v[2],
                auto_stop_seconds: v[3],
                system_audio: v[4],
                microphone: v[5],
                cursor: v[6],
                clicks: v[7],
                hide_app: v[8],
                hevc: v[9],
            }
            .normalized(),
        )
    }
}

#[derive(Debug)]
enum Phase {
    Idle,
    Countdown(Instant),
    Starting,
    Recording(Instant),
    Stopping(Duration),
}

#[repr(C)]
#[derive(Default, Debug)]
pub struct Status {
    pub phase: u32,
    pub remaining: u32,
    pub elapsed: u64,
    pub should_stop: u32,
}

pub struct Core {
    root: PathBuf,
    settings: Settings,
    destination: PathBuf,
    phase: Phase,
    output: Option<PathBuf>,
    error: String,
}
impl Core {
    fn new(root: PathBuf) -> Self {
        let settings = fs::read_to_string(root.join("settings.v1"))
            .ok()
            .and_then(|s| Settings::decode(&s))
            .unwrap_or_default();
        let destination = fs::read_to_string(root.join("destination.v1"))
            .ok()
            .map(PathBuf::from)
            .filter(|path| !path.is_absolute() && path.components().all(|part| matches!(part, std::path::Component::Normal(_))))
            .filter(|path| {
                let base = root.join("Aufnahmen").canonicalize();
                let target = root.join("Aufnahmen").join(path).canonicalize();
                matches!((base, target), (Ok(base), Ok(target)) if target.is_dir() && target.starts_with(&base))
            })
            .unwrap_or_default();
        Self {
            root,
            settings,
            destination,
            phase: Phase::Idle,
            output: None,
            error: String::new(),
        }
    }
    fn media_dir(&self) -> PathBuf {
        self.root.join("Aufnahmen")
    }
    fn destination_dir(&self) -> Result<PathBuf, String> {
        let base = self.media_dir();
        fs::create_dir_all(&base).map_err(|e| e.to_string())?;
        let base = base.canonicalize().map_err(|e| e.to_string())?;
        let target = base
            .join(&self.destination)
            .canonicalize()
            .map_err(|e| e.to_string())?;
        if !target.is_dir() || !target.starts_with(&base) {
            return Err("error.storage".into());
        }
        Ok(target)
    }
    fn set_destination(&mut self, path: &Path) -> Result<(), String> {
        if !matches!(self.phase, Phase::Idle) {
            return Err("error.settings_locked".into());
        }
        fs::create_dir_all(self.media_dir()).map_err(|e| e.to_string())?;
        let base = self.media_dir().canonicalize().map_err(|e| e.to_string())?;
        let target = path.canonicalize().map_err(|e| e.to_string())?;
        if !target.is_dir() || !target.starts_with(&base) {
            return Err("error.storage".into());
        }
        let relative = target
            .strip_prefix(&base)
            .map_err(|e| e.to_string())?
            .to_path_buf();
        let temporary = self.root.join("destination.v1.tmp");
        fs::write(&temporary, relative.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
        fs::rename(temporary, self.root.join("destination.v1")).map_err(|e| e.to_string())?;
        self.destination = relative;
        Ok(())
    }
    fn save_settings(&mut self, settings: Settings) -> Result<(), String> {
        if !matches!(self.phase, Phase::Idle) {
            return Err("error.settings_locked".into());
        }
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let next = settings.normalized();
        let temp = self.root.join("settings.v1.tmp");
        fs::write(&temp, next.encode()).map_err(|e| e.to_string())?;
        fs::rename(&temp, self.root.join("settings.v1")).map_err(|e| e.to_string())?;
        self.settings = next;
        Ok(())
    }
    fn begin(&mut self, now: Instant) -> Result<(), String> {
        if !matches!(self.phase, Phase::Idle) {
            return Err("error.busy".into());
        }
        self.destination_dir()?;
        self.output = None;
        self.error.clear();
        self.phase = if self.settings.countdown == 0 {
            Phase::Starting
        } else {
            Phase::Countdown(now + Duration::from_secs(self.settings.countdown.into()))
        };
        Ok(())
    }
    fn status(&mut self, now: Instant) -> Status {
        if let Phase::Countdown(deadline) = self.phase
            && now >= deadline
        {
            self.phase = Phase::Starting;
        }
        match self.phase {
            Phase::Idle => Status::default(),
            Phase::Countdown(deadline) => Status {
                phase: 1,
                remaining: deadline.saturating_duration_since(now).as_secs_f64().ceil() as u32,
                ..Status::default()
            },
            Phase::Starting => Status {
                phase: 2,
                ..Status::default()
            },
            Phase::Recording(start) => {
                let elapsed = now.saturating_duration_since(start).as_secs();
                Status {
                    phase: 3,
                    elapsed,
                    should_stop: u32::from(
                        self.settings.auto_stop_seconds > 0
                            && elapsed >= self.settings.auto_stop_seconds as u64,
                    ),
                    ..Status::default()
                }
            }
            Phase::Stopping(elapsed) => Status {
                phase: 4,
                elapsed: elapsed.as_secs(),
                ..Status::default()
            },
        }
    }
    fn output_path(&self, screenshot: bool) -> Result<PathBuf, String> {
        let directory = self.destination_dir()?;
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos();
        Ok(directory.join(format!(
            "{}-{stamp}-{}-{}.{}",
            if screenshot { "Screenshot" } else { "Aufnahme" },
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed),
            if screenshot { "png" } else { "mp4" }
        )))
    }
    fn recording_path(&mut self) -> Result<PathBuf, String> {
        if !matches!(self.phase, Phase::Starting) {
            return Err("error.not_ready".into());
        }
        if self.output.is_none() {
            self.output = Some(self.output_path(false)?);
        }
        self.output
            .clone()
            .ok_or_else(|| "error.missing_file".into())
    }
    fn started(&mut self, now: Instant) -> Result<(), String> {
        if !matches!(self.phase, Phase::Starting) || self.output.is_none() {
            return Err("error.state".into());
        }
        self.phase = Phase::Recording(now);
        Ok(())
    }
    fn stop(&mut self, now: Instant) -> Result<(), String> {
        match self.phase {
            Phase::Countdown(_) => {
                self.phase = Phase::Idle;
                Ok(())
            }
            Phase::Recording(start) => {
                self.phase = Phase::Stopping(now.saturating_duration_since(start));
                Ok(())
            }
            Phase::Stopping(_) => Ok(()),
            _ => Err("error.state".into()),
        }
    }
    fn finish(&mut self) -> Result<(), String> {
        if !matches!(self.phase, Phase::Recording(_) | Phase::Stopping(_)) {
            return Err("error.state".into());
        }
        self.phase = Phase::Idle;
        let output = self.output.take().ok_or("error.missing_file")?;
        let metadata = fs::metadata(output).map_err(|e| format!("error.save\t{e}"))?;
        if metadata.len() == 0 {
            return Err("error.empty_file".into());
        }
        Ok(())
    }
    fn library(&self) -> Result<String, String> {
        let dir = self.media_dir();
        if !dir.exists() {
            return Ok("[]".into());
        }
        let dir = dir.canonicalize().map_err(|e| e.to_string())?;
        let mut items = Vec::new();
        let mut directories = vec![dir];
        let mut entries = Vec::new();
        while let Some(directory) = directories.pop() {
            for entry in fs::read_dir(directory).map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                let kind = entry.file_type().map_err(|e| e.to_string())?;
                if kind.is_symlink() || entry.file_name().to_string_lossy().starts_with('.') {
                    continue;
                }
                if kind.is_dir() {
                    directories.push(entry.path());
                } else {
                    entries.push(entry);
                }
            }
        }
        for entry in entries {
            let path = entry.path();
            if entry.file_name().to_string_lossy().starts_with(".export-") {
                continue;
            }
            if self.output.as_ref() == Some(&path) {
                continue;
            }
            let kind = match path.extension().and_then(|s| s.to_str()) {
                Some("mp4" | "mov" | "m4v") => "video",
                Some("png" | "jpg" | "jpeg" | "gif" | "heic" | "tiff" | "tif" | "bmp") => "image",
                _ => continue,
            };
            let metadata = entry.metadata().map_err(|e| e.to_string())?;
            if !metadata.is_file() || metadata.len() == 0 {
                continue;
            }
            let time = metadata
                .created()
                .or_else(|_| metadata.modified())
                .unwrap_or(UNIX_EPOCH)
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs_f64();
            items.push((
                time,
                format!(
                    "{{\"path\":{},\"name\":{},\"kind\":{},\"bytes\":{},\"created\":{time}}}",
                    json(&path.to_string_lossy()),
                    json(&entry.file_name().to_string_lossy()),
                    json(kind),
                    metadata.len()
                ),
            ));
        }
        items.sort_by(|a, b| b.0.total_cmp(&a.0).then(b.1.cmp(&a.1)));
        Ok(format!(
            "[{}]",
            items.into_iter().map(|v| v.1).collect::<Vec<_>>().join(",")
        ))
    }
}
fn json(value: &str) -> String {
    let mut output = String::from("\"");
    for c in value.chars() {
        match c {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            c if c < ' ' => output.push_str(&format!("\\u{:04x}", c as u32)),
            c => output.push(c),
        }
    }
    output.push('"');
    output
}
fn owned(value: String) -> *mut c_char {
    CString::new(value.replace('\0', ""))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}
fn result(core: &mut Core, outcome: Result<(), String>) -> bool {
    match outcome {
        Ok(()) => true,
        Err(e) => {
            core.error = e;
            false
        }
    }
}
// SAFETY CONTRACT: all pointers must come from this API, remain live, and be
// accessed serially. Input C strings must be valid UTF-8, NUL-terminated strings.
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_create(root: *const c_char) -> *mut Core {
    if root.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(root) = (unsafe { CStr::from_ptr(root) }).to_str() else {
        return std::ptr::null_mut();
    };
    if !Path::new(root).is_absolute() {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(Core::new(PathBuf::from(root))))
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_destroy(core: *mut Core) {
    if !core.is_null() {
        drop(unsafe { Box::from_raw(core) });
    }
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_settings(core: *const Core) -> Settings {
    unsafe { &*core }.settings
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_save_settings(core: *mut Core, settings: Settings) -> bool {
    let core = unsafe { &mut *core };
    let r = core.save_settings(settings);
    result(core, r)
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_begin(core: *mut Core) -> bool {
    let core = unsafe { &mut *core };
    let r = core.begin(Instant::now());
    result(core, r)
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_status(core: *mut Core) -> Status {
    unsafe { &mut *core }.status(Instant::now())
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_started(core: *mut Core) -> bool {
    let core = unsafe { &mut *core };
    let r = core.started(Instant::now());
    result(core, r)
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_stop(core: *mut Core) -> bool {
    let core = unsafe { &mut *core };
    let r = core.stop(Instant::now());
    result(core, r)
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_finish(core: *mut Core) -> bool {
    let core = unsafe { &mut *core };
    let r = core.finish();
    result(core, r)
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_reset(core: *mut Core) {
    let core = unsafe { &mut *core };
    core.phase = Phase::Idle;
    core.output = None;
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_error(core: *const Core) -> *mut c_char {
    owned(unsafe { &*core }.error.clone())
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_path(core: *mut Core, screenshot: bool) -> *mut c_char {
    let core = unsafe { &mut *core };
    let path = if screenshot {
        core.output_path(true)
    } else {
        core.recording_path()
    };
    match path {
        Ok(p) => owned(p.to_string_lossy().into_owned()),
        Err(e) => {
            core.error = e;
            std::ptr::null_mut()
        }
    }
}
/// # Safety
/// Pass only live pointers from this API on a single thread. Free owned
/// output strings with `still_string_free`; never reuse freed pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_library(core: *mut Core) -> *mut c_char {
    let core = unsafe { &mut *core };
    match core.library() {
        Ok(s) => owned(s),
        Err(e) => {
            core.error = e;
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// The core and NUL-terminated UTF-8 path must be valid and used serially.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_set_destination(core: *mut Core, path: *const c_char) -> bool {
    let core = unsafe { &mut *core };
    if path.is_null() {
        return result(core, Err("error.storage".into()));
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy();
    let outcome = core.set_destination(Path::new(path.as_ref()));
    result(core, outcome)
}
/// # Safety
/// Pass a live core serially; free the returned owned string using this API.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn still_destination(core: *const Core) -> *mut c_char {
    let core = unsafe { &*core };
    owned(
        core.media_dir()
            .join(&core.destination)
            .to_string_lossy()
            .into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                    "still-test-{}-{}-{}",
                    std::process::id(),
                    NEXT_ID.fetch_add(1, Ordering::Relaxed),
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                )))
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn lifecycle_countdown_start_autostop_finalize() {
        let temp = Temp::new();
        let mut c = Core::new(temp.0.clone());
        c.settings.auto_stop_seconds = 5;
        let now = Instant::now();
        assert!(c.started(now).is_err());
        c.begin(now).unwrap();
        assert!(c.begin(now).is_err());
        assert_eq!(c.status(now).remaining, 3);
        assert!(c.recording_path().is_err());
        assert_eq!(c.status(now + Duration::from_secs(3)).phase, 2);
        let path = c.recording_path().unwrap();
        c.started(now + Duration::from_secs(3)).unwrap();
        assert_eq!(c.status(now + Duration::from_secs(7)).should_stop, 0);
        assert_eq!(c.status(now + Duration::from_secs(8)).should_stop, 1);
        assert!(c.save_settings(Settings::default()).is_err());
        fs::write(&path, b"video-test-fixture").unwrap();
        assert_eq!(c.library().unwrap(), "[]");
        c.stop(now + Duration::from_secs(8)).unwrap();
        assert_eq!(c.status(now + Duration::from_secs(100)).elapsed, 5);
        c.finish().unwrap();
        assert_eq!(c.status(now).phase, 0);
        assert!(c.library().unwrap().contains("video"));
    }
    #[test]
    fn cancellation_and_failed_output_allow_retry() {
        let temp = Temp::new();
        let mut c = Core::new(temp.0.clone());
        let now = Instant::now();
        c.begin(now).unwrap();
        c.stop(now).unwrap();
        assert_eq!(c.status(now).phase, 0);
        c.settings.countdown = 0;
        c.begin(now).unwrap();
        c.recording_path().unwrap();
        c.started(now).unwrap();
        assert!(c.finish().is_err());
        c.begin(now).unwrap();
    }
    #[test]
    fn preferences_are_validated_persisted_and_corruption_recovers() {
        let temp = Temp::new();
        let mut c = Core::new(temp.0.clone());
        let s = Settings {
            fps: 999,
            countdown: 42,
            cursor: 500,
            max_height: 2160,
            ..Settings::default()
        };
        c.save_settings(s).unwrap();
        let reopened = Core::new(temp.0.clone());
        assert_eq!(reopened.settings.fps, 30);
        assert_eq!(reopened.settings.countdown, 3);
        assert_eq!(reopened.settings.cursor, 1);
        assert_eq!(reopened.settings.max_height, 2160);
        fs::write(temp.0.join("settings.v1"), "broken").unwrap();
        assert_eq!(Core::new(temp.0.clone()).settings, Settings::default());
    }
    #[test]
    fn library_escapes_paths_and_ignores_unknown_or_empty_files() {
        let temp = Temp::new();
        let c = Core::new(temp.0.clone());
        fs::create_dir_all(c.media_dir()).unwrap();
        fs::write(c.media_dir().join("hello\"世界.png"), b"png").unwrap();
        fs::write(c.media_dir().join("partial.mp4"), b"").unwrap();
        fs::write(c.media_dir().join("private.txt"), b"secret").unwrap();
        let list = c.library().unwrap();
        assert!(list.contains("hello\\\"世界.png"));
        assert!(!list.contains("partial"));
        assert!(!list.contains("private.txt"));
        assert_eq!(json("a\n\t\u{0001}"), "\"a\\n\\t\\u0001\"");
    }
    #[test]
    fn nested_destinations_persist_and_stay_inside_library() {
        let temp = Temp::new();
        let mut c = Core::new(temp.0.clone());
        let nested = c.media_dir().join("Projects/Demo");
        fs::create_dir_all(&nested).unwrap();
        c.set_destination(&nested).unwrap();
        let reopened = Core::new(temp.0.clone());
        assert_eq!(
            reopened.destination_dir().unwrap(),
            nested.canonicalize().unwrap()
        );
        assert!(c.set_destination(&temp.0).is_err());
        let output = c.output_path(true).unwrap();
        assert_eq!(output.parent().unwrap(), nested.canonicalize().unwrap());
        fs::write(output, b"image").unwrap();
        assert!(c.library().unwrap().contains("Projects/Demo"));
        c.begin(Instant::now()).unwrap();
        assert!(c.set_destination(&nested).is_err());
    }
    #[test]
    fn ffi_roundtrip_and_string_ownership() {
        let temp = Temp::new();
        let root = CString::new(temp.0.to_str().unwrap()).unwrap();
        unsafe {
            assert!(still_create(std::ptr::null()).is_null());
            let core = still_create(root.as_ptr());
            assert!(!core.is_null());
            assert_eq!(still_settings(core).fps, 30);
            let list = still_library(core);
            assert_eq!(CStr::from_ptr(list).to_str().unwrap(), "[]");
            still_string_free(list);
            still_destroy(core);
        }
    }
}
