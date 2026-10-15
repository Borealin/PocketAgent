//! PocketAgent's serial, turn-owned DDI services. No screen stream/XCTest.
mod archive;
mod ax;
use crate::{
    IdeviceFfiError, core_device_proxy::AdapterHandle, ffi_err, rsd::RsdHandshakeHandle,
    run_sync_local,
};
use futures::StreamExt;
use idevice::{
    IdeviceError, ReadWrite, RemoteXpcClient, RsdService,
    core_device::{
        AppListEntry, AppServiceClient, ButtonState, CoreDeviceServiceClient, DataInclusionPolicy,
        ImageFormat, IndigoHidClient, KeyboardUsage, MainKeyboardService, PasteboardServiceClient,
        ScreenCaptureServiceClient, UniversalHidServiceClient,
    },
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle as NativeAdapter,
};
use plist::Value;
use serde_json::{Value as Json, json};
use std::{
    ffi::{CStr, CString, c_char},
    future::Future,
    ptr::null_mut,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

fn key_sequence(v: &Json) -> Result<(Vec<u16>, Vec<u16>), IdeviceError> {
    let keys = v["keys"].as_array().ok_or_else(|| error("DDI keys missing"))?;
    let modifiers = v["modifiers"].as_array().ok_or_else(|| error("DDI modifiers missing"))?;
    let clipboard_allowed = v["clipboard_allowed"].as_bool().ok_or_else(|| error("DDI keyboard policy missing"))?;
    if keys.is_empty() || keys.len() > 32 || modifiers.len() > 4 {
        return Err(error("DDI keyboard sequence limit"));
    }
    let keys: Vec<u16> = keys.iter().map(|v| {
        let n = v.as_u64().ok_or_else(|| error("DDI key invalid"))?;
        match n { 4..=49 | 51..=56 | 74..=75 | 77..=82 => Ok(n as u16), _ => Err(error("DDI key unsupported")) }
    }).collect::<Result<_, _>>()?;
    let modifiers: Vec<u16> = modifiers.iter().map(|v| {
        let n = v.as_u64().ok_or_else(|| error("DDI modifier invalid"))?;
        if (224..=227).contains(&n) { Ok(n as u16) } else { Err(error("DDI modifier unsupported")) }
    }).collect::<Result<_, _>>()?;
    if modifiers.iter().enumerate().any(|(i, n)| modifiers[..i].contains(n)) {
        return Err(error("DDI duplicate modifier"));
    }
    if !clipboard_allowed && modifiers.iter().any(|n| *n == 224 || *n == 227)
        && keys.iter().any(|n| [6, 25, 27].contains(n)) {
        return Err(error("DDI clipboard shortcut forbidden"));
    }
    Ok((keys, modifiers))
}

/// Stage codes reported by `pocket_ddi_progress`: metadata only. Crate-
/// visible, so they stay out of the generated C header.
pub(crate) mod stage {
    pub(crate) const IDLE: u32 = 0;
    pub(crate) const ADMIT: u32 = 1;
    pub(crate) const GEOMETRY: u32 = 2;
    pub(crate) const AX_CONNECT: u32 = 3;
    pub(crate) const AX_SETUP: u32 = 4;
    /// Detail: the AX request kind.
    pub(crate) const AX_READ: u32 = 5;
    pub(crate) const PROCESSES: u32 = 6;
    pub(crate) const LAUNCH: u32 = 7;
    pub(crate) const CLIPBOARD: u32 = 8;
    pub(crate) const TOUCH: u32 = 9;
    pub(crate) const BUTTON: u32 = 10;
    pub(crate) const KEYBOARD: u32 = 11;
    pub(crate) const WAIT: u32 = 12;
    /// Detail: the channel id.
    pub(crate) const RECONNECT: u32 = 13;
    pub(crate) const CLEANUP_TOUCH: u32 = 14;
    pub(crate) const CLEANUP_HOME: u32 = 15;
    pub(crate) const CLEANUP_KEYBOARD: u32 = 16;
    pub(crate) const AX_CLOSE: u32 = 17;
    pub(crate) const SCREENSHOT: u32 = 18;
    pub(crate) const ENCODE: u32 = 19;
}

/// Where the current call is, readable while it runs. Atomics only.
pub(crate) struct Progress {
    origin: Instant,
    seq: AtomicU64,
    in_call: AtomicBool,
    stage: AtomicU32,
    detail: AtomicU32,
    stage_at: AtomicU64,
    beats: AtomicU64,
    beat_at: AtomicU64,
    reconnects: AtomicU32,
}
impl Progress {
    fn new() -> Self {
        Self { origin: Instant::now(), seq: AtomicU64::new(0), in_call: AtomicBool::new(false),
            stage: AtomicU32::new(stage::IDLE), detail: AtomicU32::new(0), stage_at: AtomicU64::new(0),
            beats: AtomicU64::new(0), beat_at: AtomicU64::new(0), reconnects: AtomicU32::new(0) }
    }
    fn now(&self) -> u64 {
        self.origin.elapsed().as_millis() as u64
    }
    pub(crate) fn enter(&self, stage: u32, detail: u32) {
        self.stage.store(stage, Ordering::Relaxed);
        self.detail.store(detail, Ordering::Relaxed);
        self.stage_at.store(self.now(), Ordering::Relaxed);
    }
    fn begin(&self) -> CallGuard<'_> {
        self.seq.fetch_add(1, Ordering::Relaxed);
        self.in_call.store(true, Ordering::Relaxed);
        self.enter(stage::ADMIT, 0);
        CallGuard(self)
    }
    fn beat(&self) {
        self.beats.fetch_add(1, Ordering::Relaxed);
        self.beat_at.store(self.now(), Ordering::Relaxed);
    }
}
/// Marks the call finished on every return path, panics included.
struct CallGuard<'a>(&'a Progress);
impl Drop for CallGuard<'_> {
    fn drop(&mut self) {
        self.0.enter(stage::IDLE, 0);
        self.0.in_call.store(false, Ordering::Relaxed);
    }
}

/// Cancellation, its wake-up and the call's progress, allocated apart from the
/// session so Swift can signal and read it while the session is borrowed by a
/// call.
pub(crate) struct CancelState {
    flag: AtomicBool,
    notify: tokio::sync::Notify,
    /// Set only when releasing held input (touch, home, keyboard) could not be
    /// confirmed; never cleared for this session.
    input_unconfirmed: AtomicBool,
    progress: Progress,
}
impl CancelState {
    pub(crate) fn new() -> Self {
        Self { flag: AtomicBool::new(false), notify: tokio::sync::Notify::new(),
            input_unconfirmed: AtomicBool::new(false), progress: Progress::new() }
    }
    fn cancelled(&self) -> bool {
        self.flag.load(Ordering::Acquire)
    }
    fn cancel(&self) {
        self.flag.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }
    pub(crate) fn progress(&self) -> &Progress {
        &self.progress
    }
}

/// Beats once a second on the native runtime while a call runs (diagnostic
/// metadata: whether the runtime's workers and timers still ran).
struct Heartbeat(tokio::task::JoinHandle<()>);
impl Heartbeat {
    fn start(state: Arc<CancelState>) -> Self {
        Self(tokio::spawn(async move {
            loop {
                state.progress.beat();
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }))
    }
}
impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[repr(C)]
#[derive(Default, Debug)]
pub struct PocketDDIProgress {
    pub seq: u64,
    pub in_call: bool,
    pub stage: u32,
    pub detail: u32,
    pub stage_age_ms: u64,
    pub beats: u64,
    pub beat_age_ms: u64,
    pub reconnects: u32,
    pub input_unconfirmed: bool,
}

pub struct PocketDDICancellation(Arc<CancelState>);
pub struct PocketDDISession {
    ax: Option<ax::Ax>,
    adapter: NativeAdapter,
    ax_port: u16,
    hid_port: u16,
    pasteboard_port: Option<u16>,
    hit_point: Option<(f64, f64)>,
    /// Main PID and outside-app element count of the last successful snapshot.
    /// Cleared when a snapshot starts and consumed by every screen effect, so a
    /// coordinate effect is always checked against the screen observed for it.
    observed: Option<(u64, usize)>,
    hid: Channel<UniversalHidServiceClient<Box<dyn ReadWrite>>>,
    keyboard_hid: Option<Channel<UniversalHidServiceClient<Box<dyn ReadWrite>>>>,
    buttons: Channel<IndigoHidClient<Box<dyn ReadWrite>>>,
    capture: Channel<ScreenCaptureServiceClient<Box<dyn ReadWrite>>>,
    apps: Channel<AppServiceClient<Box<dyn ReadWrite>>>,
    info: Channel<CoreDeviceServiceClient<Box<dyn ReadWrite>>>,
    installed: Vec<AppListEntry>,
    cancel: Arc<CancelState>,
    keyboard: Option<MainKeyboardService>,
    touch: Option<(u16, u16)>,
    home_down: bool,
    poisoned: bool,
    effect_started: bool,
    /// Wall-clock expiry of the call in flight (Unix ms); `None` outside calls
    /// and for finalization.
    expires_at: Option<u64>,
    /// Local acceptance only: the stage at which this call stalls once.
    stall: Option<u32>,
    /// Local acceptance only: after this call's touch release has actually
    /// been sent, treat its confirmation as lost (once per session).
    drop_release: bool,
    /// Stages already stalled in this session (one-shot per stage).
    injected: u32,
}
fn error(message: impl Into<String>) -> IdeviceError {
    IdeviceError::InternalError(message.into())
}
fn request_failure(message: String, effect_started: bool, poisoned: &mut bool,
                   release_failed: bool, read_only: bool) -> Json {
    *poisoned |= effect_started || release_failed;
    let code = if release_failed { "ddi_cleanup_unconfirmed" }
        else if effect_started { "ddi_effect_unconfirmed" }
        else if *poisoned { "ddi_session_poisoned" }
        else if read_only { "ddi_observation_failed" }
        else { "ddi_preflight_refused" };
    json!({"ok":false,"code":code,"message":message,"action_issued":effect_started,
        "requires_new_turn":*poisoned,"replay_allowed":false})
}
const CANCELLED: &str = "DDI action cancelled";
const INPUT_RELEASE_UNCONFIRMED: &str = "DDI input release/removal unconfirmed; further input disabled";
const INPUT_CHANNEL_UNCERTAIN: &str = "DDI input channel uncertain while input is held; further input disabled";
/// Time-only: effects and cleanup (input sends and releases, launches, AX
/// close). Never stopped by cancellation, so a release still goes out after Stop.
async fn bounded<T, E: std::fmt::Display>(
    f: impl Future<Output = Result<T, E>>,
) -> Result<T, IdeviceError> {
    tokio::time::timeout(Duration::from_secs(4), f)
        .await
        .map_err(|_| error("DDI service request timed out"))?
        .map_err(|e| error(e.to_string()))
}
/// `None` when cancellation arrives before or while `f` runs; `f` is then
/// dropped, unpolled or mid-flight. Registered before the flag is checked, so a
/// cancel between the two still wakes it.
pub(crate) async fn until_cancelled<F: Future>(cancel: &CancelState, f: F) -> Option<F::Output> {
    let notified = cancel.notify.notified();
    tokio::pin!(notified);
    notified.as_mut().enable();
    if cancel.cancelled() {
        return None;
    }
    tokio::select! {
        biased;
        _ = &mut notified => None,
        result = f => Some(result),
    }
}
async fn cancellable<T>(
    cancel: &CancelState,
    f: impl Future<Output = Result<T, IdeviceError>>,
) -> Result<T, IdeviceError> {
    until_cancelled(cancel, f).await.unwrap_or_else(|| Err(error(CANCELLED)))
}
/// Reads, setup and reconnection: time-bounded and stopped by cancellation.
async fn bounded_call<T, E: std::fmt::Display>(
    cancel: &CancelState,
    f: impl Future<Output = Result<T, E>>,
) -> Result<T, IdeviceError> {
    cancellable(cancel, bounded(f)).await
}
#[derive(Clone, Copy, PartialEq, Debug)]
enum Wait {
    /// A call stage: cancellation ends the wait.
    Raced,
    /// Cleanup and finalization (`return`): runs although the call was cancelled.
    TimeOnly,
}
async fn bounded_in<T, E: std::fmt::Display>(
    cancel: &CancelState,
    wait: Wait,
    f: impl Future<Output = Result<T, E>>,
) -> Result<T, IdeviceError> {
    match wait {
        Wait::Raced => bounded_call(cancel, f).await,
        Wait::TimeOnly => bounded(f).await,
    }
}

/// A service client that can be replaced by a fresh connection to its port.
pub(crate) trait Reconnect: Sized {
    fn reconnect(stream: Box<dyn ReadWrite>) -> impl Future<Output = Result<Self, IdeviceError>>;
}
impl Reconnect for CoreDeviceServiceClient<Box<dyn ReadWrite>> {
    fn reconnect(stream: Box<dyn ReadWrite>) -> impl Future<Output = Result<Self, IdeviceError>> {
        CoreDeviceServiceClient::new(stream)
    }
}
macro_rules! rsd_reconnect {
    ($($client:ty),*) => {$(
        impl Reconnect for $client {
            fn reconnect(stream: Box<dyn ReadWrite>) -> impl Future<Output = Result<Self, IdeviceError>> {
                <Self as RsdService>::from_stream(stream)
            }
        }
    )*};
}
rsd_reconnect!(
    AppServiceClient<Box<dyn ReadWrite>>,
    ScreenCaptureServiceClient<Box<dyn ReadWrite>>,
    UniversalHidServiceClient<Box<dyn ReadWrite>>,
    IndigoHidClient<Box<dyn ReadWrite>>
);

/// One service connection whose requests and replies are not matched by ID:
/// once a request is dropped (deadline, cancellation) or fails, the next reply
/// read may belong to it, and a half-written frame may remain. `dirty` is set
/// before each exchange and cleared only by a successful exchange on a clean
/// client, so a dirty client never becomes trusted again; only a replacement
/// connection, installed after its handshake completes, clears it.
pub(crate) struct Channel<T> {
    client: T,
    port: u16,
    id: u32,
    dirty: bool,
}
pub(crate) mod channel {
    pub(crate) const INFO: u32 = 1;
    pub(crate) const APPS: u32 = 2;
    pub(crate) const CAPTURE: u32 = 3;
    pub(crate) const HID: u32 = 4;
    pub(crate) const BUTTONS: u32 = 5;
    pub(crate) const KEYBOARD: u32 = 6;
}
impl<T: Reconnect> Channel<T> {
    fn new(client: T, port: u16, id: u32) -> Self {
        Self { client, port, id, dirty: false }
    }
    /// Replaces a dirty client. The old one stays (still dirty) if the new
    /// connection or handshake fails.
    async fn ready(
        &mut self,
        connect: impl AsyncFnOnce(u16) -> Result<Box<dyn ReadWrite>, IdeviceError>,
        cancel: &CancelState,
        wait: Wait,
    ) -> Result<(), IdeviceError> {
        if !self.dirty {
            return Ok(());
        }
        cancel.progress.enter(stage::RECONNECT, self.id);
        let stream = bounded_in(cancel, wait, connect(self.port)).await?;
        let client = bounded_in(cancel, wait, T::reconnect(stream)).await?;
        self.client = client;
        self.dirty = false;
        cancel.progress.reconnects.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }
    /// One request/reply (or send) on the current client, without reconnecting.
    async fn exchange<R>(
        &mut self,
        f: impl AsyncFnOnce(&mut T) -> Result<R, IdeviceError>,
    ) -> Result<R, IdeviceError> {
        let was_dirty = self.dirty;
        self.dirty = true;
        let result = f(&mut self.client).await;
        if result.is_ok() && !was_dirty {
            self.dirty = false;
        }
        result
    }
    async fn request<R>(
        &mut self,
        connect: impl AsyncFnOnce(u16) -> Result<Box<dyn ReadWrite>, IdeviceError>,
        cancel: &CancelState,
        wait: Wait,
        f: impl AsyncFnOnce(&mut T) -> Result<R, IdeviceError>,
    ) -> Result<R, IdeviceError> {
        self.ready(connect, cancel, wait).await?;
        self.exchange(f).await
    }
}
/// A release counts only if it was sent on a channel that was clean before
/// cleanup began: a reply read on a desynchronised channel confirms nothing.
fn release_confirmed(sent: bool, dirty_before: bool) -> bool {
    sent && !dirty_before
}
fn connector(
    adapter: &mut NativeAdapter,
) -> impl AsyncFnOnce(u16) -> Result<Box<dyn ReadWrite>, IdeviceError> + '_ {
    async move |port| {
        let stream = adapter.connect(port).await.map_err(|e| error(e.to_string()))?;
        Ok(Box::new(stream) as Box<dyn ReadWrite>)
    }
}
fn port_of<T: RsdService>(h: &RsdHandshake) -> Result<u16, IdeviceError> {
    let name = T::rsd_service_name();
    h.services.get(name.as_ref()).map(|s| s.port).ok_or_else(|| error(format!("DDI service missing: {name}")))
}

const MAX_CALL_BUDGET_MS: u64 = 35_000;
const BUDGET_REFUSED: &str = "DDI call budget missing or exhausted; not dispatched";
const BUDGET_EXHAUSTED: &str = "DDI call budget exhausted";
/// Finalization ops keep their own cap whatever expiry field they carry.
const FINALIZATION_LIMIT: Duration = Duration::from_secs(35);
/// Wall-clock milliseconds since 1970: the clock of the app's turn deadline,
/// which counts time the process or system spent suspended.
fn unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
/// The time a call may still take: from now to the expiry the app fixed before
/// handing the call to its worker thread, at most 35 s. Handoff delay is
/// deducted, never replenished; an absent or passed expiry dispatches nothing.
fn admission_window(expires_at_ms: u64, now_ms: u64) -> Result<Duration, IdeviceError> {
    if expires_at_ms == 0 || now_ms >= expires_at_ms {
        return Err(error(BUDGET_REFUSED));
    }
    Ok(Duration::from_millis((expires_at_ms - now_ms).min(MAX_CALL_BUDGET_MS)))
}
/// Admission before each stage and physical effect: not cancelled and not past
/// the call's expiry. Cleanup and finalization never consult it.
fn admit(cancel: &CancelState, expires_at_ms: Option<u64>) -> Result<(), IdeviceError> {
    if cancel.cancelled() {
        return Err(error(CANCELLED));
    }
    if expires_at_ms.is_some_and(|expiry| unix_ms() >= expiry) {
        return Err(error(BUDGET_EXHAUSTED));
    }
    Ok(())
}
/// Local acceptance only: the stage named by `diagnostic_stall`.
fn requested_stall(v: &Json) -> Option<u32> {
    match v["diagnostic_stall"].as_str()? {
        "ax_read" => Some(stage::AX_READ),
        "geometry" => Some(stage::GEOMETRY),
        _ => None,
    }
}
/// True once per session and stage, when this call asked to stall there.
fn take_stall(requested: Option<u32>, injected: &mut u32, at: u32) -> bool {
    if requested != Some(at) || *injected & (1 << at) != 0 {
        return false;
    }
    *injected |= 1 << at;
    true
}
fn json_value(v: &Value) -> Json {
    if let Some(d) = v.as_dictionary() {
        return Json::Object(d.iter().map(|(k, v)| (k.clone(), json_value(v))).collect());
    }
    if let Some(a) = v.as_array() {
        return Json::Array(a.iter().map(json_value).collect());
    }
    if let Some(s) = v.as_string() {
        return json!(s);
    }
    if let Some(n) = v.as_unsigned_integer() {
        return json!(n);
    }
    if let Some(n) = v.as_signed_integer() {
        return json!(n);
    }
    if let Some(n) = v.as_real() {
        return json!(n);
    }
    if let Some(b) = v.as_boolean() {
        return json!(b);
    }
    Json::Null
}
fn normalized_path(raw: &str) -> String {
    let raw = raw
        .strip_prefix("file://")
        .unwrap_or(raw)
        .trim_end_matches('/');
    let raw = if raw.starts_with("/private/var/") {
        &raw[8..]
    } else {
        raw
    };
    let mut out = Vec::with_capacity(raw.len());
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(n) = std::str::from_utf8(&bytes[i + 1..i + 3])
                .ok()
                .and_then(|s| u8::from_str_radix(s, 16).ok())
                .ok_or(())
            {
                out.push(n);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
#[derive(Clone, Copy, PartialEq)]
struct Geometry {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
impl Geometry {
    fn from(v: &Value) -> Result<Self, IdeviceError> {
        let displays = v
            .as_dictionary()
            .and_then(|d| d.get("displays"))
            .and_then(Value::as_array)
            .ok_or_else(|| error("DDI display metadata missing"))?;
        let primary: Vec<_> = displays
            .iter()
            .filter_map(Value::as_dictionary)
            .filter(|d| d.get("primary").and_then(Value::as_boolean) == Some(true))
            .collect();
        if primary.len() != 1 {
            return Err(error("DDI primary display ambiguous"));
        }
        let d = primary[0];
        if ["nativeOrientation", "currentOrientation"]
            .iter()
            .any(|k| d.get(*k).and_then(Value::as_string) != Some("rot0"))
        {
            return Err(error(
                "DDI currently supports verified portrait geometry only",
            ));
        }
        let scale = d
            .get("pointScale")
            .and_then(number)
            .filter(|v| v.is_finite() && *v > 0.0)
            .ok_or_else(|| error("DDI point scale invalid"))?;
        let b = d
            .get("bounds")
            .and_then(Value::as_array)
            .ok_or_else(|| error("DDI display bounds missing"))?;
        let pairs: Vec<_> = b.iter().filter_map(Value::as_array).collect();
        if pairs.len() != 2 || pairs.iter().any(|a| a.len() != 2) {
            return Err(error("DDI display bounds invalid"));
        }
        let n: Vec<_> = pairs
            .into_iter()
            .flatten()
            .map(|v| {
                number(v)
                    .filter(|n| n.is_finite())
                    .ok_or_else(|| error("DDI coordinate invalid"))
            })
            .collect::<Result<_, _>>()?;
        if n[2] <= 0.0 || n[3] <= 0.0 {
            return Err(error("DDI display size invalid"));
        }
        Ok(Self {
            x: n[0] / scale,
            y: n[1] / scale,
            width: n[2] / scale,
            height: n[3] / scale,
        })
    }
    fn point(self, x: f64, y: f64) -> Result<(u16, u16), IdeviceError> {
        if !x.is_finite()
            || !y.is_finite()
            || x < self.x
            || y < self.y
            || x >= self.x + self.width
            || y >= self.y + self.height
        {
            return Err(error("DDI touch outside current logical screen"));
        }
        Ok((
            ((x - self.x) / self.width * 65535.0).round() as u16,
            ((y - self.y) / self.height * 65535.0).round() as u16,
        ))
    }
    fn json(self) -> Json {
        json!({"x":self.x,"y":self.y,"width":self.width,"height":self.height})
    }
}
fn json_geometry(v: &Json, message: &'static str) -> Result<Geometry, IdeviceError> {
    let d = v.as_object().ok_or_else(|| error(message))?;
    let get = |key: &str| d.get(key).and_then(Json::as_f64).filter(|n| n.is_finite()).ok_or_else(|| error(message));
    let g = Geometry { x: get("x")?, y: get("y")?, width: get("width")?, height: get("height")? };
    if g.width <= 0.0 || g.height <= 0.0 { return Err(error(message)); }
    Ok(g)
}
fn ax_field_frame(attrs: &Value, screen: Geometry) -> Result<Geometry, IdeviceError> {
    let d = attrs.as_dictionary().ok_or_else(|| error("AX field attributes missing"))?;
    if d.get("45").and_then(Value::as_unsigned_integer) != Some(15)
        || !matches!(d.get("51").and_then(Value::as_unsigned_integer), Some(0 | 1))
    { return Err(error("AX replacement requires an ordinary TextField or SearchField")); }
    if !matches!(d.get("27"), Some(v) if v.as_boolean() == Some(true) || v.as_unsigned_integer() == Some(1)) {
        return Err(error("AX replacement field is not enabled"));
    }
    if d.get("32").is_some_and(|v| v.as_boolean() == Some(false) || v.as_unsigned_integer() == Some(0)) {
        return Err(error("AX replacement field is not visible"));
    }
    let r = d.get("21").and_then(Value::as_dictionary).ok_or_else(|| error("AX field frame missing"))?;
    let get = |key: &str| r.get(key).and_then(number).filter(|n| n.is_finite()).ok_or_else(|| error("AX field frame invalid"));
    let field = Geometry { x:get("x")?, y:get("y")?, width:get("width")?, height:get("height")? };
    if field.width <= 0.0 || field.height <= 0.0 || field.x < screen.x || field.y < screen.y
        || field.x + field.width > screen.x + screen.width || field.y + field.height > screen.y + screen.height
    { return Err(error("AX field frame outside current display")); }
    Ok(field)
}
fn number(v: &Value) -> Option<f64> {
    v.as_real()
        .or_else(|| v.as_unsigned_integer().map(|n| n as f64))
        .or_else(|| v.as_signed_integer().map(|n| n as f64))
}
fn parse_identity(raw: &str) -> Result<(u64, u64), IdeviceError> {
    let (pid, object) = raw.split_once(':').ok_or_else(|| error("AX replacement identity invalid"))?;
    if object.contains(':') { return Err(error("AX replacement identity invalid")); }
    let pid = pid.parse::<u64>().ok().filter(|n| *n > 0).ok_or_else(|| error("AX replacement identity invalid"))?;
    let object = object.parse::<u64>().map_err(|_| error("AX replacement identity invalid"))?;
    Ok((pid, object))
}
impl PocketDDISession {
    async fn open(
        a: &mut NativeAdapter,
        h: &mut RsdHandshake,
        cancel: Arc<CancelState>,
    ) -> Result<Self, IdeviceError> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        let port = h
            .services
            .get("com.apple.accessibility.axAuditDaemon.remoteAXService")
            .ok_or_else(|| error("DDI AX service missing; check Developer Mode/DDI"))?
            .port;
        let ports = (|| Ok::<_, IdeviceError>((
            h.services.get("com.apple.coredevice.deviceinfo")
                .ok_or_else(|| error("DDI device info service missing"))?.port,
            port_of::<AppServiceClient<Box<dyn ReadWrite>>>(h)?,
            port_of::<ScreenCaptureServiceClient<Box<dyn ReadWrite>>>(h)?,
            port_of::<UniversalHidServiceClient<Box<dyn ReadWrite>>>(h)?,
            port_of::<IndigoHidClient<Box<dyn ReadWrite>>>(h)?,
        )))()?;
        let (info_port, apps_port, capture_port, hid_port, buttons_port) = ports;
        let stream: Box<dyn ReadWrite> = Box::new(bounded(a.connect(port)).await?);
        let mut ax = ax::Ax::new(stream, cancel.clone()).await.map_err(error)?;
        let services = tokio::time::timeout_at(deadline, async {
            let info_stream =
                bounded(async { a.connect(info_port).await.map_err(|e| error(e.to_string())) })
                    .await
                    .map_err(|e| error(format!("DDI info connect: {e}")))?;
            let info = bounded(CoreDeviceServiceClient::new(
                Box::new(info_stream) as Box<dyn ReadWrite>
            ))
            .await
            .map_err(|e| error(format!("DDI info handshake: {e}")))?;
            let mut apps = bounded(AppServiceClient::connect_rsd(a, h))
                .await
                .map_err(|e| error(format!("DDI apps connect: {e}")))?;
            let installed = tokio::time::timeout(Duration::from_secs(8), async {
                let stream = apps.stream_apps(false, true, true, true, true);
                futures::pin_mut!(stream);
                let mut result = vec![];
                while let Some(app) = stream.next().await {
                    result.push(app?);
                    if result.len() > 3000 {
                        return Err(error("DDI app inventory limit"));
                    }
                }
                Ok::<_, IdeviceError>(result)
            })
            .await
            .map_err(|_| error("DDI app inventory timed out"))??;
            let hid = bounded(UniversalHidServiceClient::connect_rsd(a, h))
                .await
                .map_err(|e| error(format!("DDI HID connect: {e}")))?;
            let buttons = bounded(IndigoHidClient::connect_rsd(a, h))
                .await
                .map_err(|e| error(format!("DDI buttons connect: {e}")))?;
            let capture = bounded(ScreenCaptureServiceClient::connect_rsd(a, h))
                .await
                .map_err(|e| error(format!("DDI screenshot connect: {e}")))?;
            Ok::<_, IdeviceError>((info, apps, installed, hid, buttons, capture))
        })
        .await
        .map_err(|_| error("DDI setup deadline"))
        .and_then(|r| r);
        let (info, apps, installed, hid, buttons, capture) = match services {
            Ok(v) => v,
            Err(e) => {
                let _ = tokio::time::timeout(Duration::from_secs(2), ax.close()).await;
                return Err(e);
            }
        };
        Ok(Self {
            ax: Some(ax),
            adapter: a.clone(),
            ax_port: port,
            hid_port,
            pasteboard_port: h
                .services
                .get("com.apple.coredevice.pasteboardservice")
                .map(|s| s.port),
            hit_point: None,
            observed: None,
            info: Channel::new(info, info_port, channel::INFO),
            apps: Channel::new(apps, apps_port, channel::APPS),
            installed,
            cancel,
            hid: Channel::new(hid, hid_port, channel::HID),
            keyboard_hid: None,
            buttons: Channel::new(buttons, buttons_port, channel::BUTTONS),
            capture: Channel::new(capture, capture_port, channel::CAPTURE),
            keyboard: None,
            touch: None,
            home_down: false,
            poisoned: false,
            effect_started: false,
            expires_at: None,
            stall: None,
            drop_release: false,
            injected: 0,
        })
    }
    /// Checked before every stage and physical effect, so a call resumed after
    /// a suspension past its expiry sends nothing more.
    fn proceed(&self) -> Result<(), IdeviceError> {
        admit(&self.cancel, self.expires_at)
    }
    async fn ax(&mut self) -> Result<&mut ax::Ax, IdeviceError> {
        if self.ax.is_none() {
            self.cancel.progress.enter(stage::AX_CONNECT, 0);
            let stream = bounded_call(&self.cancel, async {
                self.adapter
                    .connect(self.ax_port)
                    .await
                    .map_err(|e| error(e.to_string()))
            })
            .await?;
            self.cancel.progress.enter(stage::AX_SETUP, 0);
            let ax = ax::Ax::new(Box::new(stream), self.cancel.clone()).await.map_err(error)?;
            self.ax = Some(ax);
        }
        self.ax.as_mut().ok_or_else(|| error("AX session missing"))
    }
    async fn close_ax(&mut self) -> Result<&'static str, IdeviceError> {
        if let Some(mut ax) = self.ax.take() {
            self.cancel.progress.enter(stage::AX_CLOSE, 0);
            // Always drop the old socket, even when unsubscribe is unconfirmed.
            let result = tokio::time::timeout(Duration::from_secs(2), ax.close())
                .await
                .map_err(|_| { tracing::error!("DDI cleanup unconfirmed: AX unsubscribe timeout"); error("DDI AX unsubscribe timed out") })?
                .map_err(|e| { tracing::error!(reason = %e, "DDI cleanup unconfirmed: AX unsubscribe"); error(e) });
            drop(ax);
            result
        } else {
            Ok("not_observed")
        }
    }
    async fn geometry(&mut self) -> Result<Geometry, IdeviceError> {
        let cancel = self.cancel.clone();
        let stall = take_stall(self.stall, &mut self.injected, stage::GEOMETRY);
        cancel.progress.enter(stage::GEOMETRY, 0);
        let info = self.info.request(connector(&mut self.adapter), &cancel, Wait::Raced, async |c| {
            if stall {
                // Local acceptance: the request is outstanding (channel marked)
                // until Stop or the call budget ends it.
                return cancellable(&cancel, std::future::pending::<Result<Value, IdeviceError>>()).await;
            }
            bounded_call(&cancel, c.invoke_with_plist(
                "com.apple.coredevice.feature.getdisplayinfo",
                plist::Dictionary::new(),
            ))
            .await
        })
        .await?;
        Geometry::from(&info)
    }
    async fn bundle_for_pid(&mut self, pid: u64) -> Result<String, IdeviceError> {
        let cancel = self.cancel.clone();
        cancel.progress.enter(stage::PROCESSES, 0);
        // Only the wire exchange marks the channel; a complete reply that does
        // not name the process leaves it clean.
        let processes = self.apps.request(connector(&mut self.adapter), &cancel, Wait::Raced,
            async |c| bounded_call(&cancel, c.list_processes()).await).await?;
        let path = processes
            .iter()
            .find(|p| p.pid as u64 == pid)
            .and_then(|p| p.executable_url.as_ref())
            .map(|p| normalized_path(&p.relative))
            .ok_or_else(|| error("AX foreground process path unavailable"))?;
        let matches: Vec<_> = self
            .installed
            .iter()
            .filter(|a| path.starts_with(&(normalized_path(&a.path) + "/")))
            .collect();
        if matches.len() == 1 {
            return Ok(matches[0].bundle_identifier.clone());
        }
        // Exact system executable paths, not name/prefix guesses for user apps.
        match path.as_str() {
            "/System/Library/CoreServices/SpringBoard.app/SpringBoard" => {
                Ok("com.apple.springboard".into())
            }
            "/Applications/Spotlight.app/Spotlight" => Ok("com.apple.Spotlight".into()),
            _ => Err(error("AX foreground bundle identity unavailable")),
        }
    }
    async fn active_hit(&mut self, g: Geometry) -> Result<(u64, f64, f64), IdeviceError> {
        let mut points = vec![];
        if let Some(point) = self.hit_point {
            points.push(point);
        }
        for point in [
            (0.5, 0.5),
            (0.5, 0.36),
            (0.5, 0.2),
            (0.2, 0.2),
            (0.8, 0.2),
            (0.2, 0.5),
            (0.8, 0.5),
            (0.5, 0.8),
            (0.2, 0.8),
            (0.8, 0.8),
        ] {
            if !points.contains(&point) {
                points.push(point);
            }
        }
        for (fx, fy) in points {
            let x = g.x + g.width * fx;
            let y = g.y + g.height * fy;
            match self.ax().await?.hit(x, y).await {
                Ok(token) => {
                    let (pid, _) = ax::identity(&token).map_err(error)?;
                    self.hit_point = Some((fx, fy));
                    return Ok((pid, x, y));
                }
                // A blank point has no AX element on the tested device. This
                // is a complete semantic refusal, not a timed-out request.
                Err(e) if e == "AX request type 6 refused: 8" => continue,
                Err(e) => return Err(error(e)),
            }
        }
        Err(error("AX foreground has no readable hit point"))
    }
    /// A coordinate effect must land on the app of the snapshot observed for
    /// it: that app must still be foreground and own the element at the point.
    /// UI hosted by another process (for example the keyboard's system paste
    /// suggestion) is outside the observed graph, so a point it covers, or a
    /// point whose owner cannot be confirmed while such UI is on screen, is
    /// refused before any touch.
    async fn require_owned_point(&mut self, scope: Option<(u64, usize)>, x: f64, y: f64) -> Result<(), IdeviceError> {
        let (pid, outside) = scope.ok_or_else(|| error(POINT_UNOBSERVED))?;
        let g = self.geometry().await?;
        let (foreground, _, _) = self.active_hit(g).await?;
        if foreground != pid {
            return Err(error(FOREGROUND_NOT_OBSERVED));
        }
        let hit = match self.ax().await?.hit(x, y).await {
            Ok(token) => Ok(ax::identity(&token).map_err(error)?.0),
            Err(e) => Err(e),
        };
        point_owner(pid, outside, hit).map_err(error)
    }
    async fn foreground(&mut self) -> Result<String, IdeviceError> {
        let g = self.geometry().await?;
        let (pid, _, _) = self.active_hit(g).await?;
        self.bundle_for_pid(pid).await
    }
    async fn snapshot(&mut self) -> Result<Json, IdeviceError> {
        self.observed = None;
        if take_stall(self.stall, &mut self.injected, stage::AX_READ) {
            self.ax().await?.stall_next_read = true;
        }
        let before = self.geometry().await?;
        let (selected_pid, x, y) = self.active_hit(before).await?;
        let ax::Graph { pid, nodes, outside } = self.ax().await?.graph(x, y).await.map_err(error)?;
        if pid != selected_pid {
            return Err(error("AX foreground or root changed"));
        }
        self.proceed()?;
        let bundle = self.bundle_for_pid(pid).await?;
        if self.geometry().await? != before {
            return Err(error("DDI display changed during observation"));
        }
        let mut result = vec![];
        for attrs in nodes {
            let mut d = attrs
                .into_dictionary()
                .ok_or_else(|| error("AX node missing"))?;
            let token = d
                .remove("token")
                .ok_or_else(|| error("AX node token missing"))?;
            let (pid, object) = ax::identity(&token).map_err(error)?;
            d.remove("8");
            let mut node = json_value(&Value::Dictionary(d));
            node["identity"] = json!(format!("{pid}:{object}"));
            result.push(node);
        }
        self.observed = Some((pid, outside));
        Ok(json!({"app":bundle,"frame":before.json(),"nodes":result,"source":"ddi_ax","atomic":false,
            "outside_app_elements":outside}))
    }
    async fn wait(&self, millis: u64) -> Result<(), IdeviceError> {
        self.proceed()?;
        self.cancel.progress.enter(stage::WAIT, millis.min(u32::MAX as u64) as u32);
        cancellable(&self.cancel, async {
            tokio::time::sleep(Duration::from_millis(millis)).await;
            Ok(())
        })
        .await?;
        self.proceed()
    }
    async fn touch(
        &mut self,
        from: (u16, u16),
        to: (u16, u16),
        seconds: f64,
        drag: bool,
    ) -> Result<(), IdeviceError> {
        if !seconds.is_finite() || !(0.05..=3.0).contains(&seconds) {
            return Err(error("DDI gesture duration invalid"));
        }
        let steps = if drag {
            (seconds * 60.0).ceil() as u32
        } else {
            1
        };
        let cancel = self.cancel.clone();
        for i in 0..=steps {
            self.proceed()?;
            let t = if drag { i as f64 / steps as f64 } else { 0.0 };
            let p = (
                (from.0 as f64 + (to.0 as f64 - from.0 as f64) * t).round() as u16,
                (from.1 as f64 + (to.1 as f64 - from.1 as f64) * t).round() as u16,
            );
            // Held contact belongs to this channel: never reconnect under it.
            if self.hid.dirty && self.touch.is_some() {
                return Err(error(INPUT_CHANNEL_UNCERTAIN));
            }
            cancel.progress.enter(stage::TOUCH, 0);
            self.hid.ready(connector(&mut self.adapter), &cancel, Wait::Raced).await?;
            // Stop or expiry during a reconnect: no contact is sent.
            self.proceed()?;
            self.effect_started = true;
            self.touch = Some(p); // Before write: failure may have delivered contact.
            self.hid.exchange(async |c| bounded(c.send_touchscreen(0xC2, p.0, p.1, None)).await).await?;
            if i < steps {
                self.wait((seconds * 1000.0 / steps as f64).round() as u64)
                    .await?;
            }
        }
        Ok(())
    }
    async fn key(&mut self, codes: &[u16], expected: Option<&str>) -> Result<(), IdeviceError> {
        self.proceed()?;
        let cancel = self.cancel.clone();
        if self.keyboard.is_none() {
            // Model inference can leave the setup connection idle before the
            // first key. Open a fresh channel before creating an owned service;
            // this is preparation, never a retry of a keyboard effect.
            if self.touch.is_some() {
                return Err(error("DDI keyboard preparation while contact is held"));
            }
            cancel.progress.enter(stage::KEYBOARD, 0);
            let stream = bounded_call(&cancel, self.adapter.connect(self.hid_port)).await?;
            let mut client = bounded_call(&cancel, RemoteXpcClient::new(Box::new(stream) as Box<dyn ReadWrite>)).await?;
            bounded_call(&cancel, client.do_handshake()).await?;
            self.proceed()?;
            let channel = self.keyboard_hid.insert(
                Channel::new(UniversalHidServiceClient::new(client), self.hid_port, channel::KEYBOARD));
            self.effect_started = true; // A failed constructor can have created an owned service.
            // Device-owned state with its own bounded rollback: not raced.
            self.keyboard = Some(channel.exchange(async |c| c.create_main_keyboard().await
                .map_err(|e| error(e.to_string()))).await?);
            self.wait(200).await?;
        }
        if let Some(expected) = expected {
            if self.foreground().await? != expected {
                return Err(error("AX foreground or root changed"));
            }
        }
        for code in codes {
            self.proceed()?;
            cancel.progress.enter(stage::KEYBOARD, *code as u32);
            let usage = KeyboardUsage::new(*code).map_err(|e| error(e.to_string()))?;
            let keyboard = self.keyboard.as_mut().ok_or_else(|| error("DDI keyboard missing"))?;
            let hid = self.keyboard_hid.as_mut().ok_or_else(|| error("DDI keyboard channel missing"))?;
            self.effect_started = true;
            hid.exchange(async |c| bounded(c.main_keyboard_key_down(keyboard, usage)).await).await?;
            self.wait(20).await?;
        }
        self.wait(60).await?;
        // Captured Device Hub chord: {Cmd}, {Cmd,V}, {V}, {}.
        // Explicit HID key-up reports are required; resetGestureState alone
        // does not send an empty keyboard report.
        for code in codes {
            let usage = KeyboardUsage::new(*code).map_err(|e| error(e.to_string()))?;
            let keyboard = self.keyboard.as_mut().ok_or_else(|| error("DDI keyboard missing"))?;
            self.keyboard_hid.as_mut().ok_or_else(|| error("DDI keyboard channel missing"))?
                .exchange(async |c| bounded(c.main_keyboard_key_up(keyboard, usage)).await).await?;
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        Ok(())
    }
    /// Releases held input on the channels that hold it, never through a new
    /// connection. Time-only, so it runs after Stop. Each channel's dirty state
    /// is taken once before its release: a reply read on a desynchronised
    /// channel confirms nothing. An unconfirmed release poisons the session and
    /// sets the typed `input_unconfirmed` outcome.
    async fn cleanup_input(&mut self, remove_keyboard: bool) -> Result<(), IdeviceError> {
        let cancel = self.cancel.clone();
        let mut unconfirmed = 0;
        if let Some((x, y)) = self.touch {
            cancel.progress.enter(stage::CLEANUP_TOUCH, 0);
            let dirty_before = self.hid.dirty;
            let sent = self.hid.exchange(async |c| bounded(c.send_touchscreen(0x02, x, y, None)).await).await;
            // Local acceptance: the release went out; only its confirmation is dropped.
            let dropped = sent.is_ok() && take_stall(self.drop_release.then_some(stage::CLEANUP_TOUCH),
                &mut self.injected, stage::CLEANUP_TOUCH);
            if release_confirmed(sent.is_ok(), dirty_before) && !dropped {
                self.touch = None;
            } else {
                if dropped {
                    tracing::warn!("diagnostic: touch release sent, its confirmation dropped");
                    self.touch = None;
                }
                tracing::error!(dirty_before, "DDI cleanup unconfirmed: touch release");
                unconfirmed += 1;
            }
        }
        if self.home_down {
            cancel.progress.enter(stage::CLEANUP_HOME, 0);
            let dirty_before = self.buttons.dirty;
            let sent = self.buttons.exchange(async |c| bounded(c.send_button(12, 64, ButtonState::Up)).await).await;
            if release_confirmed(sent.is_ok(), dirty_before) {
                self.home_down = false;
            } else {
                tracing::error!(dirty_before, "DDI cleanup unconfirmed: home release");
                unconfirmed += 1;
            }
        }
        if let Some(keyboard) = self.keyboard.as_mut() {
            cancel.progress.enter(stage::CLEANUP_KEYBOARD, 0);
            match self.keyboard_hid.as_mut() {
                None => {
                    tracing::error!("DDI cleanup unconfirmed: owned keyboard channel missing");
                    unconfirmed += 1;
                }
                Some(hid) => {
                    let dirty_before = hid.dirty;
                    let mut sent = true;
                    if let Err(e) = hid.exchange(async |c|
                        bounded(c.set_main_keyboard_usages(keyboard, Vec::<KeyboardUsage>::new())).await).await {
                        tracing::error!(reason = %e, "DDI cleanup unconfirmed: keyboard release");
                        sent = false;
                    }
                    let mut removed = false;
                    if remove_keyboard {
                        if let Err(e) = hid.exchange(async |c| bounded(c.reset_main_keyboard(keyboard)).await).await {
                            tracing::error!(reason = %e, "DDI cleanup unconfirmed: keyboard reset");
                            sent = false;
                        }
                        match hid.exchange(async |c| bounded(c.remove_main_keyboard(keyboard)).await).await {
                            Ok(()) => removed = true,
                            Err(e) => { tracing::error!(reason = %e, "DDI cleanup unconfirmed: keyboard removal"); sent = false; }
                        }
                    }
                    if !release_confirmed(sent, dirty_before) {
                        if dirty_before { tracing::error!("DDI cleanup unconfirmed: keyboard channel was desynchronised"); }
                        unconfirmed += 1;
                    } else if removed {
                        self.keyboard = None;
                        self.keyboard_hid = None;
                    }
                }
            }
        }
        if unconfirmed == 0 {
            Ok(())
        } else {
            self.poisoned = true;
            cancel.input_unconfirmed.store(true, Ordering::Release);
            Err(error(INPUT_RELEASE_UNCONFIRMED))
        }
    }
    async fn call(&mut self, v: &Json) -> Result<Json, IdeviceError> {
        let op = v["op"]
            .as_str()
            .ok_or_else(|| error("DDI operation missing"))?;
        if op == "stop_observing" {
            let stop = self.close_ax().await?;
            return Ok(json!({"subscription_stop": stop,
                "subscription_acknowledged": stop == "acknowledged", "connection_closed": true}));
        }
        if op == "return" {
            let bundle = v["bundle_id"]
                .as_str()
                .ok_or_else(|| error("DDI return bundle missing"))?;
            // Finalization runs with the cancel flag still set after Stop: a
            // dirty channel is reconnected and the launch sent, time-only.
            let cancel = self.cancel.clone();
            cancel.progress.enter(stage::LAUNCH, 0);
            self.apps.ready(connector(&mut self.adapter), &cancel, Wait::TimeOnly).await?;
            self.effect_started = true;
            self.apps.exchange(async |c|
                bounded(c.launch_application(bundle, &[], false, false, None, None, None)).await).await?;
            return Ok(json!({}));
        }
        self.proceed()?;
        if self.poisoned && !["apps", "foreground", "snapshot", "clipboard_verify"].contains(&op) {
            return Err(error(
                "DDI input is disabled after an uncertain effect; observe and send a new turn",
            ));
        }
        let expected = v["expected_app"].as_str();
        // Every screen effect consumes the observed scope; the next coordinate
        // effect needs a fresh successful snapshot.
        let scope = if ["tap", "hold", "drag", "surface_drag", "clear", "paste", "key", "keys", "ax_replace", "activate", "home"].contains(&op) {
            self.observed.take()
        } else {
            None
        };
        if ["tap", "hold", "drag", "surface_drag", "clear", "paste", "key", "keys", "ax_replace"].contains(&op) {
            if let Some(frame) = v["expected_frame"].as_object() {
                let g = self.geometry().await?;
                for (k, n) in [
                    ("x", g.x),
                    ("y", g.y),
                    ("width", g.width),
                    ("height", g.height),
                ] {
                    if frame.get(k).and_then(Json::as_f64) != Some(n) {
                        return Err(error("DDI display changed before effect"));
                    }
                }
            }
            if let Some(expected) = expected {
                if self.foreground().await? != expected {
                    return Err(error("AX foreground or root changed"));
                }
            }
            self.proceed()?;
        }
        match op {
            "apps" => Ok(
                json!({"apps":self.installed.iter().map(|a|json!({"bundle_id":a.bundle_identifier,"name":a.name})).collect::<Vec<_>>()}),
            ),
            "foreground" => Ok(json!({"app":self.foreground().await?})),
            "snapshot" => self.snapshot().await,
            "ax_replace" => {
                let identity = v["identity"].as_str().ok_or_else(|| error("AX replacement identity missing"))?;
                let text = v["text"].as_str().filter(|s| !s.is_empty() && s.len() <= 16_000)
                    .ok_or_else(|| error("AX replacement text must be nonempty and at most 16000 UTF-8 bytes"))?;
                if v["clear"].as_bool() != Some(true) { return Err(error("AX replacement requires clear=true")); }
                let expected_app = expected.ok_or_else(|| error("AX replacement expected app missing"))?;
                let expected_screen = json_geometry(&v["expected_frame"], "AX replacement expected display frame missing or invalid")?;
                let target_rect = json_geometry(&v["target_frame"], "AX replacement target frame missing or invalid")?;
                let screen = self.geometry().await?;
                if screen != expected_screen || self.foreground().await? != expected_app {
                    return Err(error("AX replacement app or display changed"));
                }
                let (selected_pid, x, y) = self.active_hit(screen).await?;
                let ax::Graph { pid: graph_pid, nodes, .. } = self.ax().await?.graph(x, y).await.map_err(error)?;
                if graph_pid != selected_pid || self.bundle_for_pid(graph_pid).await? != expected_app {
                    return Err(error("AX replacement foreground changed"));
                }
                let (target_pid, target_object) = parse_identity(identity)?;
                if target_pid != graph_pid { return Err(error("AX replacement identity belongs to another process")); }
                let attrs = nodes.iter().find(|node| node.as_dictionary().and_then(|d| d.get("token"))
                    .and_then(|token| ax::identity(token).ok()) == Some((target_pid, target_object)))
                    .ok_or_else(|| error("AX replacement field is absent from fresh complete graph"))?;
                let field_rect = ax_field_frame(attrs, screen)?;
                if field_rect != target_rect { return Err(error("AX replacement target frame changed")); }
                let token = attrs.as_dictionary().and_then(|d| d.get("token"))
                    .ok_or_else(|| error("AX replacement token missing"))?.clone();
                let center_x = field_rect.x + field_rect.width / 2.0;
                let center_y = field_rect.y + field_rect.height / 2.0;
                if self.geometry().await? != screen || self.foreground().await? != expected_app {
                    return Err(error("AX replacement app or display changed before effect"));
                }
                let hit = self.ax().await?.hit(center_x, center_y).await.map_err(error)?;
                if ax::identity(&hit).map_err(error)? != (target_pid, target_object) {
                    return Err(error("AX replacement target is covered or changed"));
                }
                self.proceed()?;
                // Reconnection is read preparation; the setter is the effect.
                self.ax().await?;
                self.effect_started = true;
                self.ax.as_mut().ok_or_else(|| error("AX session missing"))?
                    .set_text(&token, text).await.map_err(error)?;
                self.proceed()?;
                Ok(json!({"action_issued":true,"replay_allowed":false,"route":"ax-set-value"}))
            }
            "clipboard_set" | "clipboard_verify" => {
                let expected = v["text"]
                    .as_str()
                    .ok_or_else(|| error("DDI clipboard text missing"))?;
                let port = self
                    .pasteboard_port
                    .ok_or_else(|| error("DDI clipboard readback service unavailable"))?;
                // One fresh transaction avoids assigning a late reply to another
                // operation. Resolve only the primary text representation.
                self.cancel.progress.enter(stage::CLIPBOARD, 0);
                let stream = bounded_call(&self.cancel, self.adapter.connect(port)).await?;
                let mut client = bounded_call(&self.cancel, RemoteXpcClient::new(stream)).await?;
                bounded_call(&self.cancel, client.do_handshake()).await?;
                let mut client = PasteboardServiceClient::new(client);
                if op == "clipboard_set" {
                    self.proceed()?;
                    self.effect_started = true;
                    bounded(client.set_text(expected, "general")).await?;
                    self.proceed()?;
                }
                let current = bounded_call(
                    &self.cancel,
                    client.get_with_policy("general", DataInclusionPolicy::PromiseSecondary),
                )
                .await?;
                if current.text().as_deref() != Some(expected) {
                    return Err(error(
                        "DDI clipboard contents changed or unavailable; paste not sent",
                    ));
                }
                Ok(json!({"verified":true}))
            }
            "activate" => {
                let bundle = v["bundle_id"]
                    .as_str()
                    .ok_or_else(|| error("DDI bundle ID missing"))?;
                if !self.installed.iter().any(|a| a.bundle_identifier == bundle) {
                    return Err(error("DDI app is not installed"));
                }
                // Activate an existing process; never terminate the target or
                // the assistant whose turn owns this session.
                self.proceed()?;
                let cancel = self.cancel.clone();
                cancel.progress.enter(stage::LAUNCH, 0);
                // Reconnecting is preparation (stopped by Stop); the launch is
                // an effect and is not raced.
                self.apps.ready(connector(&mut self.adapter), &cancel, Wait::Raced).await?;
                self.proceed()?;
                self.effect_started = true;
                self.apps.exchange(async |c|
                    bounded(c.launch_application(bundle, &[], false, false, None, None, None)).await).await?;
                Ok(json!({}))
            }
            "tap" | "hold" | "drag" => {
                let g = self.geometry().await?;
                self.proceed()?;
                let num = |key: &str| {
                    v[key]
                        .as_f64()
                        .ok_or_else(|| error("DDI coordinate missing"))
                };
                let from = g.point(num("x")?, num("y")?)?;
                let to = if op == "drag" {
                    g.point(num("to_x")?, num("to_y")?)?
                } else {
                    from
                };
                let seconds = if op == "tap" { 0.05 } else { num("seconds")? };
                self.require_owned_point(scope, num("x")?, num("y")?).await?;
                self.proceed()?;
                self.touch(from, to, seconds, op == "drag").await?;
                Ok(json!({}))
            }
            "surface_drag" => {
                // Executor-internal compaction of the system task surface on
                // Dynamic Island layouts (never a model action). The status band
                // belongs to SpringBoard, so instead of point ownership it is
                // bounded to a short leftward swipe inside that band while the
                // observed app is still foreground.
                let (pid, _) = scope.ok_or_else(|| error(POINT_UNOBSERVED))?;
                let g = self.geometry().await?;
                let (foreground, _, _) = self.active_hit(g).await?;
                if foreground != pid {
                    return Err(error(FOREGROUND_NOT_OBSERVED));
                }
                let num = |key: &str| v[key].as_f64().ok_or_else(|| error("DDI coordinate missing"));
                let (x, to_x, y, seconds) = (num("x")?, num("to_x")?, num("y")?, num("seconds")?);
                surface_gesture(&g, x, to_x, y, seconds).map_err(error)?;
                self.proceed()?;
                self.touch(g.point(x, y)?, g.point(to_x, y)?, seconds, true).await?;
                Ok(json!({}))
            }
            "home" => {
                self.proceed()?;
                if self.buttons.dirty && self.home_down {
                    return Err(error(INPUT_CHANNEL_UNCERTAIN));
                }
                let cancel = self.cancel.clone();
                cancel.progress.enter(stage::BUTTON, 0);
                self.buttons.ready(connector(&mut self.adapter), &cancel, Wait::Raced).await?;
                self.proceed()?;
                self.effect_started = true;
                self.home_down = true;
                self.buttons.exchange(async |c| bounded(c.send_button(12, 64, ButtonState::Down)).await).await?;
                self.wait(80).await?;
                Ok(json!({}))
            }
            "key" => {
                let key = v["key"].as_str().ok_or_else(|| error("DDI key missing"))?;
                self.key(
                    &[match key {
                        "return" => 40,
                        "delete" => 42,
                        "escape" => 41,
                        _ => return Err(error("DDI key unsupported")),
                    }],
                    expected,
                )
                .await?;
                Ok(json!({}))
            }
            "clear" => {
                self.key(&[0xe3, 4], expected).await?;
                self.proceed()?;
                self.key(&[42], expected).await?;
                Ok(json!({}))
            }
            "keys" => {
                let (keys, modifiers) = key_sequence(v)?;
                for code in keys {
                    self.proceed()?;
                    let mut chord = modifiers.clone();
                    chord.push(code);
                    self.key(&chord, expected).await?;
                }
                Ok(json!({}))
            }
            // The executor prepares and verifies the device clipboard service
            // before this chord; it does not use foreground UIKit writes.
            "paste" => {
                self.key(&[0xe3, 25], expected).await?;
                Ok(json!({}))
            }
            _ => Err(error("Unknown DDI operation")),
        }
    }
    async fn screenshot(&mut self, stall: bool) -> Result<Vec<u8>, IdeviceError> {
        self.proceed()?;
        let cancel = self.cancel.clone();
        cancel.progress.enter(stage::SCREENSHOT, 0);
        self.capture.request(connector(&mut self.adapter), &cancel, Wait::Raced, async |c| {
            if stall {
                return cancellable(&cancel, std::future::pending::<Result<Vec<u8>, IdeviceError>>()).await;
            }
            bounded_call(&cancel, c.take_screenshot(None, ImageFormat::Png)).await
        })
        .await
    }
}

// Effect refusals before any touch; all end in "not tapped".
const POINT_UNOBSERVED: &str = "DDI effect point has no current observation; not tapped";
const FOREGROUND_NOT_OBSERVED: &str = "DDI foreground is not the observed app; not tapped";
const POINT_COVERED: &str = "DDI target is covered by another process's UI; not tapped";
const POINT_UNCONFIRMED: &str = "DDI target owner cannot be confirmed while UI of another process is on screen; not tapped";
const BLANK_POINT: &str = "AX request type 6 refused: 8";

const SURFACE_OUTSIDE_BAND: &str = "DDI surface gesture outside the status band; not tapped";

/// The internal task-surface gesture: a leftward swipe starting in the right
/// half, ending no further left than 30% of the width, inside the top 5% of
/// the display, lasting 0.1–0.5 s.
fn surface_gesture(g: &Geometry, x: f64, to_x: f64, y: f64, seconds: f64) -> Result<(), String> {
    let inside = [x, to_x, y, seconds].iter().all(|v| v.is_finite())
        && y >= g.y && y <= g.y + g.height * 0.05
        && x >= g.x + g.width * 0.5 && x < g.x + g.width
        && to_x < x && to_x >= g.x + g.width * 0.3
        && (0.1..=0.5).contains(&seconds);
    if inside { Ok(()) } else { Err(SURFACE_OUTSIDE_BAND.into()) }
}

/// Ownership of the element at an effect point. The observed app's own element
/// passes; another process's element refuses. A point without an AX element
/// (refusal 8) passes only when the observation read the whole screen (no
/// outside-app elements); otherwise its owner cannot be confirmed.
fn point_owner(observed: u64, outside: usize, hit: Result<u64, String>) -> Result<(), String> {
    match hit {
        Ok(pid) if pid == observed => Ok(()),
        Ok(_) => Err(POINT_COVERED.into()),
        Err(e) if e == BLANK_POINT && outside == 0 => Ok(()),
        Err(e) if e == BLANK_POINT => Err(POINT_UNCONFIRMED.into()),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod keyboard_sequence_tests {
    use super::*;

    #[test]
    fn clipboard_policy_blocks_modified_copy_cut_paste_before_hid() {
        for key in [6, 25, 27] {
            for modifier in [224, 227] {
                assert!(key_sequence(&json!({"keys":[key],"modifiers":[225,modifier],"clipboard_allowed":false})).is_err());
            }
        }
        assert!(key_sequence(&json!({"keys":[4],"modifiers":[227],"clipboard_allowed":false})).is_ok());
        assert!(key_sequence(&json!({"keys":[25],"modifiers":[227],"clipboard_allowed":true})).is_ok());
    }

    #[test]
    fn validates_whole_bounded_sequence_before_any_input() {
        for value in [json!({"keys":[],"modifiers":[],"clipboard_allowed":false}),
            json!({"keys":vec![4;33],"modifiers":[],"clipboard_allowed":false}),
            json!({"keys":[4,0x4f60],"modifiers":[],"clipboard_allowed":false}),
            json!({"keys":[4],"modifiers":[227,227],"clipboard_allowed":true}),
            json!({"keys":[4],"modifiers":[]})] {
            assert!(key_sequence(&value).is_err());
        }
        assert_eq!(key_sequence(&json!({"keys":[17,12,11,4,18],"modifiers":[],"clipboard_allowed":false})).unwrap(), (vec![17,12,11,4,18],vec![]));
    }
}

/// # Safety
/// Borrowed adapter/handshake and output pointers must be valid. The caller
/// serializes all operations and frees the DDI session before tunnel handles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_open(
    a: *mut AdapterHandle,
    h: *mut RsdHandshakeHandle,
    out: *mut *mut PocketDDISession,
    cancel: *mut *mut PocketDDICancellation,
) -> *mut IdeviceFfiError {
    if a.is_null() || h.is_null() || out.is_null() || cancel.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    unsafe {
        *out = null_mut();
        *cancel = null_mut();
    }
    let state = Arc::new(CancelState::new());
    let result = run_sync_local(PocketDDISession::open(
        unsafe { &mut (*a).0 },
        unsafe { &mut (*h).0 },
        state.clone(),
    ));
    match result {
        Ok(session) => {
            unsafe {
                *out = Box::into_raw(Box::new(session));
                *cancel = Box::into_raw(Box::new(PocketDDICancellation(state)));
            }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}
/// # Safety
/// Cancellation is independently allocated and may be signalled while a serial
/// session call is running. Do not free it until that call has completed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_cancel(cancel: *mut PocketDDICancellation) {
    if !cancel.is_null() {
        let state: &CancelState = unsafe { &(*cancel).0 };
        state.cancel();
    }
}
/// # Safety
/// Reset only before dispatching a new call, with no call in flight.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_reset_cancel(cancel: *mut PocketDDICancellation) {
    if !cancel.is_null() {
        let state: &CancelState = unsafe { &(*cancel).0 };
        state.flag.store(false, Ordering::Release);
    }
}
/// # Safety
/// `cancel` is a live cancellation from pocket_ddi_open that pocket_ddi_close
/// has not consumed. Reads atomics only and never touches the session, so it
/// may run while a call is in flight.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_progress(
    cancel: *const PocketDDICancellation,
    out: *mut PocketDDIProgress,
) -> bool {
    if cancel.is_null() || out.is_null() {
        return false;
    }
    let state = unsafe { &(*cancel).0 };
    let p = &state.progress;
    let now = p.now();
    unsafe {
        *out = PocketDDIProgress {
            seq: p.seq.load(Ordering::Relaxed),
            in_call: p.in_call.load(Ordering::Relaxed),
            stage: p.stage.load(Ordering::Relaxed),
            detail: p.detail.load(Ordering::Relaxed),
            stage_age_ms: now.saturating_sub(p.stage_at.load(Ordering::Relaxed)),
            beats: p.beats.load(Ordering::Relaxed),
            beat_age_ms: now.saturating_sub(p.beat_at.load(Ordering::Relaxed)),
            reconnects: p.reconnects.load(Ordering::Relaxed),
            input_unconfirmed: state.input_unconfirmed.load(Ordering::Acquire),
        };
    }
    true
}
/// # Safety
/// A single caller owns the session. Request is a bounded NUL-terminated JSON
/// string; output is released with idevice_string_free. No request/result logs.
/// Every operation except the finalization ops `stop_observing` and `return`
/// requires `expires_at_ms` (wall-clock Unix ms, fixed by the app before the
/// handoff); a missing or passed expiry dispatches nothing and is an error.
/// Once admitted, the output is a JSON object with `ok`, `action_issued`
/// (whether this request started a physical effect) and `replay_allowed`
/// false; a failure adds `code`, `message` and `requires_new_turn` (input
/// stays disabled for this session) instead of returning an error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_call(
    handle: *mut PocketDDISession,
    request: *const c_char,
    out: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if handle.is_null() || request.is_null() || out.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    unsafe {
        *out = null_mut();
    }
    let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
    if bytes.len() > 64 * 1024 {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let value = match serde_json::from_slice::<Json>(bytes) {
        Ok(v) => v,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidArg),
    };
    let session = unsafe { &mut *handle };
    let state = session.cancel.clone();
    let _call = state.progress.begin();
    // Err only when admission refuses before anything runs; afterwards every
    // outcome is a result carrying its effect metadata.
    let result: Result<Json, IdeviceError> = run_sync_local(async {
        let _beat = Heartbeat::start(state.clone());
        let op = value["op"].as_str().unwrap_or("");
        let finalization = matches!(op, "stop_observing" | "return");
        let window = if finalization {
            session.expires_at = None;
            FINALIZATION_LIMIT
        } else {
            let now = unix_ms();
            let window = admission_window(value["expires_at_ms"].as_u64().unwrap_or(0), now)?;
            session.expires_at = Some(now + window.as_millis() as u64);
            window
        };
        session.stall = if finalization { None } else { requested_stall(&value) };
        session.drop_release = !finalization && value["diagnostic_release_unconfirmed"].as_bool() == Some(true);
        session.effect_started = false;
        let result = tokio::time::timeout(window, session.call(&value))
            .await
            .map_err(|_| {
                tracing::warn!(stage = state.progress.stage.load(Ordering::Relaxed),
                    detail = state.progress.detail.load(Ordering::Relaxed), "DDI call budget exhausted");
                error(BUDGET_EXHAUSTED)
            });
        // Cleanup below runs without the call's expiry.
        session.expires_at = None;
        session.stall = None;
        if session.cancel.cancelled() {
            tracing::warn!(stage = state.progress.stage.load(Ordering::Relaxed), "DDI call cancelled");
        }
        let cleanup = session
            .cleanup_input(session.cancel.cancelled())
            .await;
        session.drop_release = false;
        if let Err(e) = cleanup {
            let _ = session.close_ax().await;
            return Ok(request_failure(e.to_string(), session.effect_started, &mut session.poisoned, true, false));
        }
        match result {
            Ok(Ok(mut v)) => {
                v["ok"] = json!(true);
                v["action_issued"] = json!(session.effect_started);
                v["replay_allowed"] = json!(false);
                Ok(v)
            }
            Ok(Err(e)) | Err(e) => {
                // Abort semantic AX correlation after any failed operation.
                // Read-only recovery may reconnect; uncertain effects never replay.
                let _ = session.close_ax().await;
                let read_only = ["apps", "foreground", "snapshot", "clipboard_verify"].contains(&op);
                Ok(request_failure(e.to_string(), session.effect_started, &mut session.poisoned, false, read_only))
            }
        }
    });
    state.progress.enter(stage::ENCODE, 0);
    match result {
        Ok(v) => match serde_json::to_string(&v)
            .ok()
            .and_then(|s| CString::new(s).ok())
        {
            Some(s) => {
                unsafe {
                    *out = s.into_raw();
                }
                null_mut()
            }
            None => ffi_err!(error("DDI result encoding")),
        },
        Err(e) => ffi_err!(e),
    }
}
/// # Safety
/// Session is valid, no other call in flight. Buffer is freed with
/// pocket_ddi_bytes_free using its exact returned length. `expires_at_ms`
/// (wall-clock Unix ms, fixed by the app before the handoff) bounds the call; a
/// missing or passed expiry dispatches nothing. `diagnostic_stall` is 0, or 1
/// (local acceptance only) to stall the capture once per session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_screenshot(
    handle: *mut PocketDDISession,
    expires_at_ms: u64,
    diagnostic_stall: u32,
    out: *mut *mut u8,
    len: *mut usize,
) -> *mut IdeviceFfiError {
    if handle.is_null() || out.is_null() || len.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    unsafe {
        *out = null_mut();
        *len = 0;
    }
    let now = unix_ms();
    let window = match admission_window(expires_at_ms, now) {
        Ok(window) => window,
        Err(e) => return ffi_err!(e),
    };
    let session = unsafe { &mut *handle };
    let state = session.cancel.clone();
    let _call = state.progress.begin();
    let result = run_sync_local(async {
        let _beat = Heartbeat::start(state.clone());
        session.expires_at = Some(now + window.as_millis() as u64);
        let requested = (diagnostic_stall == 1).then_some(stage::SCREENSHOT);
        let stall = take_stall(requested, &mut session.injected, stage::SCREENSHOT);
        let result = tokio::time::timeout(window, session.screenshot(stall))
            .await
            .map_err(|_| {
                tracing::warn!("DDI screenshot budget exhausted");
                error(BUDGET_EXHAUSTED)
            });
        session.expires_at = None;
        result?
    });
    match result {
        Ok(data) if data.len() <= 32 * 1024 * 1024 => {
            let data = data.into_boxed_slice();
            unsafe {
                *len = data.len();
                *out = Box::into_raw(data) as *mut u8;
            }
            null_mut()
        }
        Ok(_) => ffi_err!(error("DDI screenshot size limit")),
        Err(e) => ffi_err!(e),
    }
}
/// # Safety
/// Free only an unfreed screenshot allocation with its original length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_bytes_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, len)) });
    }
}
/// # Safety
/// No call in flight. Consumes both handles even when cleanup is unconfirmed.
/// `input_unconfirmed` (nullable) receives whether releasing held input was
/// left unconfirmed at any point in this session, close included; an AX
/// unsubscribe failure is reported only through the returned error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_close(
    handle: *mut PocketDDISession,
    cancel: *mut PocketDDICancellation,
    input_unconfirmed: *mut bool,
) -> *mut IdeviceFfiError {
    if !input_unconfirmed.is_null() {
        unsafe { *input_unconfirmed = false };
    }
    if !cancel.is_null() {
        drop(unsafe { Box::from_raw(cancel) });
    }
    if handle.is_null() {
        return null_mut();
    }
    let mut session = unsafe { Box::from_raw(handle) };
    let result = run_sync_local(async {
        let input = session.cleanup_input(true).await;
        let ax = session.close_ax().await;
        input?;
        ax.map(|_| ())
    });
    if !input_unconfirmed.is_null() {
        unsafe { *input_unconfirmed = session.cancel.input_unconfirmed.load(Ordering::Acquire) };
    }
    drop(session);
    match result {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

#[cfg(test)]
mod call_lifecycle_tests {
    use super::*;
    use std::{collections::VecDeque, sync::atomic::AtomicUsize};

    fn state() -> Arc<CancelState> {
        Arc::new(CancelState::new())
    }
    fn message(e: IdeviceError) -> String {
        match e {
            IdeviceError::InternalError(m) => m,
            other => other.to_string(),
        }
    }
    /// A device service that answers every request without tagging the reply:
    /// the next reply read is whatever the device queued first.
    #[derive(Default)]
    struct Wire {
        replies: VecDeque<u32>,
        fresh: bool,
    }
    impl Reconnect for Wire {
        fn reconnect(_: Box<dyn ReadWrite>) -> impl Future<Output = Result<Self, IdeviceError>> {
            async { Ok(Wire { replies: VecDeque::new(), fresh: true }) }
        }
    }
    impl Wire {
        /// Sends request `n` (the device queues its reply), then reads one
        /// reply unless `stall`, where the caller never gets to read it.
        async fn call(&mut self, n: u32, stall: bool) -> Result<u32, IdeviceError> {
            self.replies.push_back(n);
            if stall {
                std::future::pending::<()>().await;
            }
            Ok(self.replies.pop_front().expect("queued reply"))
        }
    }
    fn counting(count: &AtomicUsize) -> impl AsyncFnOnce(u16) -> Result<Box<dyn ReadWrite>, IdeviceError> + '_ {
        async move |_| {
            count.fetch_add(1, Ordering::SeqCst);
            Ok(Box::new(tokio::io::duplex(64).0) as Box<dyn ReadWrite>)
        }
    }

    #[tokio::test]
    async fn a_cancelled_call_stage_is_never_polled() {
        let cancel = state();
        cancel.cancel();
        let polled = AtomicUsize::new(0);
        let result = bounded_call(&cancel, async {
            polled.fetch_add(1, Ordering::SeqCst);
            Ok::<_, IdeviceError>(())
        })
        .await;
        assert_eq!(message(result.unwrap_err()), CANCELLED);
        assert_eq!(polled.load(Ordering::SeqCst), 0);
    }
    #[tokio::test]
    async fn cancellation_ends_an_unanswered_read_promptly() {
        let cancel = state();
        let signal = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(30)).await;
            signal.cancel();
        });
        let started = Instant::now();
        let result = bounded_call(&cancel, std::future::pending::<Result<(), IdeviceError>>()).await;
        assert_eq!(message(result.unwrap_err()), CANCELLED);
        assert!(started.elapsed() < Duration::from_millis(1000));
    }
    #[tokio::test]
    async fn cleanup_and_finalization_waits_ignore_cancellation() {
        let cancel = state();
        cancel.cancel();
        assert_eq!(bounded(async { Ok::<_, IdeviceError>(7) }).await.unwrap(), 7);
        assert_eq!(bounded_in(&cancel, Wait::TimeOnly, async { Ok::<_, IdeviceError>(8) }).await.unwrap(), 8);
        assert!(bounded_in(&cancel, Wait::Raced, async { Ok::<_, IdeviceError>(9) }).await.is_err());
    }
    #[tokio::test]
    async fn a_reply_left_by_a_dropped_request_never_answers_the_next_one() {
        let cancel = state();
        let connects = AtomicUsize::new(0);
        let mut channel = Channel::new(Wire::default(), 1, channel::INFO);
        // Request 1 is sent; its future is dropped at a deadline before the reply is read.
        let dropped = tokio::time::timeout(Duration::from_millis(20),
            channel.request(counting(&connects), &cancel, Wait::Raced, async |w| w.call(1, true).await)).await;
        assert!(dropped.is_err() && channel.dirty);
        // Request 2 gets its own reply over a new connection, never reply 1.
        let answer = channel.request(counting(&connects), &cancel, Wait::Raced, async |w| w.call(2, false).await)
            .await.unwrap();
        assert_eq!((answer, connects.load(Ordering::SeqCst)), (2, 1));
        assert!(!channel.dirty && channel.client.fresh);
        // A clean channel is reused.
        channel.request(counting(&connects), &cancel, Wait::Raced, async |w| w.call(3, false).await).await.unwrap();
        assert_eq!(connects.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn a_desynchronised_client_confirms_nothing_until_replaced() {
        let mut channel = Channel::new(Wire::default(), 1, channel::KEYBOARD);
        let _ = tokio::time::timeout(Duration::from_millis(20), channel.exchange(async |w| w.call(1, true).await)).await;
        // Without a replacement the next "reply" belongs to the dropped request.
        // It is returned, but the channel stays dirty and a release sent on it
        // does not count as confirmed.
        let dirty_before = channel.dirty;
        let reply = channel.exchange(async |w| w.call(2, false).await).await.unwrap();
        assert_eq!(reply, 1);
        assert!(dirty_before && channel.dirty);
        assert!(!release_confirmed(true, dirty_before));
        assert!(release_confirmed(true, false) && !release_confirmed(false, false));
    }
    #[tokio::test]
    async fn a_failed_reconnect_keeps_the_old_client_marked() {
        let cancel = state();
        let mut channel = Channel::new(Wire { replies: VecDeque::from([9]), fresh: false }, 1, channel::APPS);
        channel.dirty = true;
        let result = channel.request(async |_| Err::<Box<dyn ReadWrite>, _>(error("refused")), &cancel, Wait::Raced,
            async |w| w.call(1, false).await).await;
        assert!(result.is_err());
        assert!(channel.dirty && !channel.client.fresh && channel.client.replies == [9]);
    }
    #[tokio::test]
    async fn finalization_reconnects_and_sends_although_the_call_was_cancelled() {
        let cancel = state();
        cancel.cancel();
        let connects = AtomicUsize::new(0);
        let mut apps = Channel::new(Wire::default(), 1, channel::APPS);
        apps.dirty = true;
        // A call stage stops at the cancellation without connecting.
        assert!(apps.request(counting(&connects), &cancel, Wait::Raced, async |w| w.call(1, false).await).await.is_err());
        assert_eq!(connects.load(Ordering::SeqCst), 0);
        // `return` reconnects and launches, time-only.
        let sent = apps.request(counting(&connects), &cancel, Wait::TimeOnly, async |w| bounded(w.call(2, false)).await)
            .await.unwrap();
        assert_eq!((sent, connects.load(Ordering::SeqCst)), (2, 1));
    }
    #[test]
    fn the_expiry_fixed_before_the_handoff_is_never_replenished() {
        // Missing or passed: nothing is dispatched.
        for (expiry, now) in [(0, 1_000), (1_000, 1_000), (1_000, 2_000)] {
            assert_eq!(message(admission_window(expiry, now).unwrap_err()), BUDGET_REFUSED);
        }
        // Time spent before the worker started is deducted.
        assert_eq!(admission_window(10_000, 4_000).unwrap(), Duration::from_millis(6_000));
        assert_eq!(admission_window(10_000, 9_999).unwrap(), Duration::from_millis(1));
        // At most 35 s, however far away the expiry.
        assert_eq!(admission_window(u64::MAX, 0).unwrap(), Duration::from_millis(MAX_CALL_BUDGET_MS));
    }
    #[test]
    fn admission_refuses_after_the_expiry_or_cancellation() {
        let cancel = state();
        assert!(admit(&cancel, None).is_ok());
        assert!(admit(&cancel, Some(unix_ms() + 60_000)).is_ok());
        assert_eq!(message(admit(&cancel, Some(unix_ms() - 1)).unwrap_err()), BUDGET_EXHAUSTED);
        cancel.cancel();
        assert_eq!(message(admit(&cancel, None).unwrap_err()), CANCELLED);
    }
    /// The primitives `touch` and `cleanup_input` use, in their order: each
    /// step is admitted before it is sent; the release is not admitted.
    #[tokio::test]
    async fn expiry_mid_gesture_stops_the_next_send_but_not_the_release() {
        let cancel = state();
        let expiry = Some(unix_ms() + 60);
        let mut hid = Channel::new(Wire::default(), 1, channel::HID);
        let mut sent = 0;
        let stopped = loop {
            if let Err(e) = admit(&cancel, expiry) {
                break e;
            }
            hid.exchange(async |w| w.call(sent, false).await).await.unwrap();
            sent += 1;
            tokio::time::sleep(Duration::from_millis(25)).await;
        };
        assert_eq!(message(stopped), BUDGET_EXHAUSTED);
        assert!((1..=4).contains(&sent));
        let dirty_before = hid.dirty;
        let released = hid.exchange(async |w| bounded(w.call(99, false)).await).await;
        assert_eq!(released.unwrap(), 99);
        assert!(release_confirmed(true, dirty_before));
    }
    #[test]
    fn a_diagnostic_stall_happens_once_per_session_and_stage() {
        let mut injected = 0;
        assert!(!take_stall(None, &mut injected, stage::GEOMETRY));
        assert!(!take_stall(Some(stage::AX_READ), &mut injected, stage::GEOMETRY));
        assert!(take_stall(Some(stage::GEOMETRY), &mut injected, stage::GEOMETRY));
        assert!(!take_stall(Some(stage::GEOMETRY), &mut injected, stage::GEOMETRY));
        assert!(take_stall(Some(stage::AX_READ), &mut injected, stage::AX_READ));
        assert_eq!(requested_stall(&json!({"op":"snapshot","diagnostic_stall":"geometry"})), Some(stage::GEOMETRY));
        assert_eq!(requested_stall(&json!({"op":"snapshot"})), None);
        assert_eq!(requested_stall(&json!({"diagnostic_stall":"tap"})), None);
    }
    #[tokio::test]
    async fn progress_is_readable_during_a_call_and_the_heartbeat_stops_after() {
        let state = state();
        let handle = Box::into_raw(Box::new(PocketDDICancellation(state.clone())));
        let read = || {
            let mut p = PocketDDIProgress::default();
            assert!(unsafe { pocket_ddi_progress(handle, &mut p) });
            p
        };
        {
            let _call = state.progress.begin();
            state.progress.enter(stage::AX_READ, 5);
            let beat = Heartbeat::start(state.clone());
            tokio::time::sleep(Duration::from_millis(1100)).await;
            let p = read();
            assert!(p.in_call && p.seq == 1 && p.stage == stage::AX_READ && p.detail == 5);
            assert!(p.beats >= 2 && p.beat_age_ms < 1100 && p.stage_age_ms >= 1000);
            drop(beat);
            tokio::task::yield_now().await;
            let beats = state.progress.beats.load(Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(1100)).await;
            assert_eq!(state.progress.beats.load(Ordering::SeqCst), beats);
        }
        let p = read();
        assert!(!p.in_call && p.stage == stage::IDLE && !p.input_unconfirmed);
        state.input_unconfirmed.store(true, Ordering::Release);
        assert!(read().input_unconfirmed);
        assert!(!unsafe { pocket_ddi_progress(null_mut(), &mut PocketDDIProgress::default()) });
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refused_preflight_remains_usable_but_uncertain_effect_does_not() {
        let mut poisoned = false;
        let refused = request_failure("field frame changed".into(), false, &mut poisoned, false, false);
        assert_eq!(refused["code"], "ddi_preflight_refused");
        assert_eq!(refused["action_issued"], false);
        assert_eq!(refused["requires_new_turn"], false);
        assert!(!poisoned);
        let uncertain = request_failure("setter reply timed out".into(), true, &mut poisoned, false, false);
        assert_eq!(uncertain["code"], "ddi_effect_unconfirmed");
        assert_eq!(uncertain["action_issued"], true);
        assert_eq!(uncertain["requires_new_turn"], true);
        assert!(poisoned);
        let blocked = request_failure("input disabled".into(), false, &mut poisoned, false, false);
        assert_eq!(blocked["code"], "ddi_session_poisoned");
        assert_eq!(blocked["action_issued"], false);
        assert_eq!(blocked["requires_new_turn"], true);
        assert_eq!(blocked["replay_allowed"], false);
    }

    #[test]
    fn failed_owned_release_disables_input_even_after_a_read_only_request() {
        let mut poisoned = false;
        let failure = request_failure("key release failed".into(), false, &mut poisoned, true, true);
        assert_eq!(failure["code"], "ddi_cleanup_unconfirmed");
        assert_eq!(failure["requires_new_turn"], true);
        assert_eq!(failure["action_issued"], false);
        assert!(poisoned);
    }

    #[test]
    fn fractional_target_frames_keep_the_exact_swift_json_round_trip() {
        // Real AX coordinate that previously moved by one f64 ULP under the
        // default serde_json parser, falsely refusing an unchanged field.
        let expected = 23.317333333333334_f64;
        let frame: Json = serde_json::from_str(
            r#"{"x":23.317333333333334,"y":94.66666666666667,"width":328.36533333333335,"height":36.666666666666664}"#
        ).unwrap();
        assert_eq!(frame["x"].as_f64().unwrap().to_bits(), expected.to_bits());
        let encoded = serde_json::to_string(&frame).unwrap();
        let decoded: Json = serde_json::from_str(&encoded).unwrap();
        for key in ["x", "y", "width", "height"] {
            assert_eq!(frame[key].as_f64().unwrap().to_bits(), decoded[key].as_f64().unwrap().to_bits());
        }
    }
    #[test]
    fn task_surface_gesture_stays_in_the_status_band() {
        let g = Geometry { x: 0.0, y: 0.0, width: 393.0, height: 852.0 };
        // The executor's gesture: 90% → 55% of the width at 42% of a 59 pt inset.
        assert_eq!(surface_gesture(&g, 353.7, 216.15, 24.78, 0.25), Ok(()));
        for (x, to_x, y, seconds) in [
            (353.7, 216.15, 60.0, 0.25),   // below the status band (content area)
            (353.7, 216.15, -1.0, 0.25),   // above the display
            (100.0, 50.0, 24.78, 0.25),    // starts in the left half
            (216.15, 353.7, 24.78, 0.25),  // rightward
            (353.7, 50.0, 24.78, 0.25),    // ends too far left
            (353.7, 216.15, 24.78, 2.0),   // too long
            (f64::NAN, 216.15, 24.78, 0.25),
        ] {
            assert_eq!(surface_gesture(&g, x, to_x, y, seconds).unwrap_err(), SURFACE_OUTSIDE_BAND);
        }
    }
    #[test]
    fn effect_points_must_belong_to_the_observed_app() {
        assert_eq!(point_owner(7, 0, Ok(7)), Ok(()));
        assert_eq!(point_owner(7, 2, Ok(7)), Ok(()));
        assert_eq!(point_owner(7, 0, Ok(9)).unwrap_err(), POINT_COVERED);
        assert_eq!(point_owner(7, 2, Ok(9)).unwrap_err(), POINT_COVERED);
        // A blank point is accepted only on a completely read screen.
        assert_eq!(point_owner(7, 0, Err(BLANK_POINT.into())), Ok(()));
        assert_eq!(point_owner(7, 1, Err(BLANK_POINT.into())).unwrap_err(), POINT_UNCONFIRMED);
        assert_eq!(point_owner(7, 0, Err("AX semantic request timed out; session must close".into())).unwrap_err(),
                   "AX semantic request timed out; session must close");
        for refusal in [POINT_UNOBSERVED, FOREGROUND_NOT_OBSERVED, POINT_COVERED, POINT_UNCONFIRMED, SURFACE_OUTSIDE_BAND] {
            assert!(refusal.ends_with("; not tapped"));
        }
    }
    #[test]
    fn ax_replacement_eligibility_requires_enabled_visible_ordinary_single_line_field() {
        let screen = Geometry { x: 0.0, y: 0.0, width: 390.0, height: 844.0 };
        let field = |role: u64, subrole: u64, enabled: bool, visible: bool, x: f64| archive::fields(&[
            ("45", role.into()), ("51", subrole.into()), ("27", enabled.into()), ("32", visible.into()),
            ("21", archive::fields(&[("x", x.into()), ("y", 100.0.into()), ("width", 200.0.into()), ("height", 44.0.into())])),
        ]);
        assert_eq!(ax_field_frame(&field(15u64, 0u64, true, true, 20.0), screen).unwrap().x, 20.0);
        assert!(ax_field_frame(&field(15u64, 1u64, true, true, 20.0), screen).is_ok());
        for attrs in [field(15u64, 5u64, true, true, 20.0), field(17u64, 0u64, true, true, 20.0),
            field(15u64, 0u64, false, true, 20.0), field(15u64, 0u64, true, false, 20.0),
            field(15u64, 0u64, true, true, 200.0)] { assert!(ax_field_frame(&attrs, screen).is_err()); }
        let missing_subrole = archive::fields(&[("45", 15u64.into()), ("27", true.into()), ("32", true.into()),
            ("21", archive::fields(&[("x", 1.0.into()), ("y", 1.0.into()), ("width", 2.0.into()), ("height", 2.0.into())]))]);
        assert!(ax_field_frame(&missing_subrole, screen).is_err());
    }
    #[test]
    fn ax_replacement_identity_requires_exact_pid_object_pair() {
        assert_eq!(parse_identity("12:34").unwrap(), (12, 34));
        for invalid in ["0:1", "1:x", "1:2:3", "-1:2", "01:02junk"] { assert!(parse_identity(invalid).is_err()); }
    }
    #[test]
    fn logical_touch_bounds_and_scaled_display() {
        let display = archive::fields(&[
            ("primary", true.into()),
            ("nativeOrientation", "rot0".into()),
            ("currentOrientation", "rot0".into()),
            ("pointScale", 3.0.into()),
            (
                "bounds",
                Value::Array(vec![
                    Value::Array(vec![0u64.into(), 0u64.into()]),
                    Value::Array(vec![1125u64.into(), 2436u64.into()]),
                ]),
            ),
        ]);
        let info = archive::fields(&[("displays", Value::Array(vec![display]))]);
        let g = Geometry::from(&info).unwrap();
        assert_eq!(g.width, 375.0);
        assert_eq!(g.height, 812.0);
        assert_eq!(g.point(187.5, 406.0).unwrap(), (32768, 32768));
        assert!(g.point(f64::NAN, 0.0).is_err());
        assert!(g.point(375.0, 0.0).is_err());
        assert!(g.point(-1.0, 0.0).is_err());
    }
}
