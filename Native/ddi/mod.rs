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
    ptr::null_mut,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
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

pub struct PocketDDICancellation(Arc<AtomicBool>);
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
    hid: UniversalHidServiceClient<Box<dyn ReadWrite>>,
    keyboard_hid: Option<UniversalHidServiceClient<Box<dyn ReadWrite>>>,
    buttons: IndigoHidClient<Box<dyn ReadWrite>>,
    capture: ScreenCaptureServiceClient<Box<dyn ReadWrite>>,
    apps: AppServiceClient<Box<dyn ReadWrite>>,
    info: CoreDeviceServiceClient<Box<dyn ReadWrite>>,
    installed: Vec<AppListEntry>,
    cancel: Arc<AtomicBool>,
    keyboard: Option<MainKeyboardService>,
    touch: Option<(u16, u16)>,
    home_down: bool,
    poisoned: bool,
}
fn error(message: impl Into<String>) -> IdeviceError {
    IdeviceError::InternalError(message.into())
}
async fn bounded<T, E: std::fmt::Display>(
    f: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, IdeviceError> {
    tokio::time::timeout(Duration::from_secs(4), f)
        .await
        .map_err(|_| error("DDI service request timed out"))?
        .map_err(|e| error(e.to_string()))
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
        cancel: Arc<AtomicBool>,
    ) -> Result<Self, IdeviceError> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        let port = h
            .services
            .get("com.apple.accessibility.axAuditDaemon.remoteAXService")
            .ok_or_else(|| error("DDI AX service missing; check Developer Mode/DDI"))?
            .port;
        let stream: Box<dyn ReadWrite> = Box::new(bounded(a.connect(port)).await?);
        let mut ax = ax::Ax::new(stream).await.map_err(error)?;
        let services = tokio::time::timeout_at(deadline, async {
            let info_port = h
                .services
                .get("com.apple.coredevice.deviceinfo")
                .ok_or_else(|| error("DDI device info service missing"))?
                .port;
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
            hid_port: h.services.get("com.apple.coredevice.hid.universalhidservice")
                .ok_or_else(|| error("DDI HID service missing"))?.port,
            pasteboard_port: h
                .services
                .get("com.apple.coredevice.pasteboardservice")
                .map(|s| s.port),
            hit_point: None,
            observed: None,
            info,
            apps,
            installed,
            cancel,
            hid,
            keyboard_hid: None,
            buttons,
            capture,
            keyboard: None,
            touch: None,
            home_down: false,
            poisoned: false,
        })
    }
    fn proceed(&self) -> Result<(), IdeviceError> {
        if self.cancel.load(Ordering::Acquire) {
            return Err(error("DDI action cancelled"));
        }
        Ok(())
    }
    async fn ax(&mut self) -> Result<&mut ax::Ax, IdeviceError> {
        if self.ax.is_none() {
            let stream = bounded(async {
                self.adapter
                    .connect(self.ax_port)
                    .await
                    .map_err(|e| error(e.to_string()))
            })
            .await?;
            let ax = ax::Ax::new(Box::new(stream)).await.map_err(error)?;
            self.ax = Some(ax);
        }
        self.ax.as_mut().ok_or_else(|| error("AX session missing"))
    }
    async fn close_ax(&mut self) -> Result<&'static str, IdeviceError> {
        if let Some(mut ax) = self.ax.take() {
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
        let info = bounded(self.info.invoke_with_plist(
            "com.apple.coredevice.feature.getdisplayinfo",
            plist::Dictionary::new(),
        ))
        .await?;
        Geometry::from(&info)
    }
    async fn bundle_for_pid(&mut self, pid: u64) -> Result<String, IdeviceError> {
        let processes = bounded(self.apps.list_processes()).await?;
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
        let mut remaining = millis;
        while remaining > 0 {
            self.proceed()?;
            let n = remaining.min(20);
            tokio::time::sleep(Duration::from_millis(n)).await;
            remaining -= n;
        }
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
        for i in 0..=steps {
            self.proceed()?;
            let t = if drag { i as f64 / steps as f64 } else { 0.0 };
            let p = (
                (from.0 as f64 + (to.0 as f64 - from.0 as f64) * t).round() as u16,
                (from.1 as f64 + (to.1 as f64 - from.1 as f64) * t).round() as u16,
            );
            self.touch = Some(p); // Before write: failure may have delivered contact.
            bounded(self.hid.send_touchscreen(0xC2, p.0, p.1, None)).await?;
            if i < steps {
                self.wait((seconds * 1000.0 / steps as f64).round() as u64)
                    .await?;
            }
        }
        Ok(())
    }
    async fn key(&mut self, codes: &[u16], expected: Option<&str>) -> Result<(), IdeviceError> {
        self.proceed()?;
        if self.keyboard.is_none() {
            // Model inference can leave the setup connection idle before the
            // first key. Open a fresh channel before creating an owned service;
            // this is preparation, never a retry of a keyboard effect.
            if self.touch.is_some() {
                return Err(error("DDI keyboard preparation while contact is held"));
            }
            let stream = bounded(self.adapter.connect(self.hid_port)).await?;
            let mut client = bounded(RemoteXpcClient::new(Box::new(stream) as Box<dyn ReadWrite>)).await?;
            bounded(client.do_handshake()).await?;
            self.keyboard_hid = Some(UniversalHidServiceClient::new(client));
            self.proceed()?;
            self.keyboard = Some(
                self.keyboard_hid.as_mut().ok_or_else(|| error("DDI keyboard channel missing"))?
                    .create_main_keyboard()
                    .await
                    .map_err(|e| error(e.to_string()))?,
            );
            self.wait(200).await?;
        }
        if let Some(expected) = expected {
            if self.foreground().await? != expected {
                return Err(error("AX foreground or root changed"));
            }
        }
        for code in codes {
            self.proceed()?;
            bounded(
                self.keyboard_hid.as_mut().ok_or_else(|| error("DDI keyboard channel missing"))?.main_keyboard_key_down(
                    self.keyboard
                        .as_mut()
                        .ok_or_else(|| error("DDI keyboard missing"))?,
                    KeyboardUsage::new(*code).map_err(|e| error(e.to_string()))?,
                ),
            )
            .await?;
            self.wait(20).await?;
        }
        self.wait(60).await?;
        // Captured Device Hub chord: {Cmd}, {Cmd,V}, {V}, {}.
        // Explicit HID key-up reports are required; resetGestureState alone
        // does not send an empty keyboard report.
        for code in codes {
            bounded(
                self.keyboard_hid.as_mut().ok_or_else(|| error("DDI keyboard channel missing"))?.main_keyboard_key_up(
                    self.keyboard
                        .as_mut()
                        .ok_or_else(|| error("DDI keyboard missing"))?,
                    KeyboardUsage::new(*code).map_err(|e| error(e.to_string()))?,
                ),
            )
            .await?;
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        Ok(())
    }
    async fn cleanup_input(&mut self, remove_keyboard: bool) -> Result<(), IdeviceError> {
        let mut errors = vec![];
        if let Some((x, y)) = self.touch {
            match bounded(self.hid.send_touchscreen(0x02, x, y, None)).await {
                Ok(()) => self.touch = None,
                Err(e) => errors.push(e),
            }
        }
        if self.home_down {
            match bounded(self.buttons.send_button(12, 64, ButtonState::Up)).await {
                Ok(()) => self.home_down = false,
                Err(e) => errors.push(e),
            }
        }
        if let Some(keyboard) = self.keyboard.as_mut() {
            let hid = self.keyboard_hid.as_mut().ok_or_else(|| error("DDI owned keyboard channel missing"))?;
            if let Err(e) = bounded(
                hid
                    .set_main_keyboard_usages(keyboard, Vec::<KeyboardUsage>::new()),
            )
            .await
            {
                tracing::error!("DDI cleanup unconfirmed: keyboard release");
                errors.push(e);
            }
        }
        if remove_keyboard {
            if let Some(keyboard) = self.keyboard.as_mut() {
                let hid = self.keyboard_hid.as_mut().ok_or_else(|| error("DDI owned keyboard channel missing"))?;
                if let Err(e) = bounded(hid.reset_main_keyboard(keyboard)).await {
                    tracing::error!("DDI cleanup unconfirmed: keyboard reset");
                    errors.push(e);
                }
                match bounded(hid.remove_main_keyboard(keyboard)).await {
                    Ok(()) => { self.keyboard = None; self.keyboard_hid = None; },
                    Err(e) => { tracing::error!("DDI cleanup unconfirmed: keyboard removal"); errors.push(e); },
                }
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            self.poisoned = true;
            Err(error(
                "DDI input release/removal unconfirmed; further input disabled",
            ))
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
            bounded(
                self.apps
                    .launch_application(bundle, &[], false, false, None, None, None),
            )
            .await?;
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
        let scope = if ["tap", "hold", "drag", "clear", "paste", "key", "keys", "ax_replace", "activate", "home"].contains(&op) {
            self.observed.take()
        } else {
            None
        };
        if ["tap", "hold", "drag", "clear", "paste", "key", "keys", "ax_replace"].contains(&op) {
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
                self.ax().await?.set_text(&token, text).await.map_err(error)?;
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
                let stream = bounded(self.adapter.connect(port)).await?;
                let mut client = bounded(RemoteXpcClient::new(stream)).await?;
                bounded(client.do_handshake()).await?;
                let mut client = PasteboardServiceClient::new(client);
                if op == "clipboard_set" {
                    self.proceed()?;
                    bounded(client.set_text(expected, "general")).await?;
                    self.proceed()?;
                }
                let current = bounded(
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
                bounded(
                    self.apps
                        .launch_application(bundle, &[], false, false, None, None, None),
                )
                .await?;
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
            "home" => {
                self.proceed()?;
                self.home_down = true;
                bounded(self.buttons.send_button(12, 64, ButtonState::Down)).await?;
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
}

// Effect refusals before any touch; all end in "not tapped".
const POINT_UNOBSERVED: &str = "DDI effect point has no current observation; not tapped";
const FOREGROUND_NOT_OBSERVED: &str = "DDI foreground is not the observed app; not tapped";
const POINT_COVERED: &str = "DDI target is covered by another process's UI; not tapped";
const POINT_UNCONFIRMED: &str = "DDI target owner cannot be confirmed while UI of another process is on screen; not tapped";
const BLANK_POINT: &str = "AX request type 6 refused: 8";

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
    let flag = Arc::new(AtomicBool::new(false));
    let result = run_sync_local(PocketDDISession::open(
        unsafe { &mut (*a).0 },
        unsafe { &mut (*h).0 },
        flag.clone(),
    ));
    match result {
        Ok(session) => {
            unsafe {
                *out = Box::into_raw(Box::new(session));
                *cancel = Box::into_raw(Box::new(PocketDDICancellation(flag)));
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
        unsafe {
            (*cancel).0.store(true, Ordering::Release);
        }
    }
}
/// # Safety
/// Reset only before dispatching a new call, with no call in flight.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_reset_cancel(cancel: *mut PocketDDICancellation) {
    if !cancel.is_null() {
        unsafe {
            (*cancel).0.store(false, Ordering::Release);
        }
    }
}
/// # Safety
/// A single caller owns the session. Request is a bounded NUL-terminated JSON
/// string; output is released with idevice_string_free. No request/result logs.
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
    let result = run_sync_local(async {
        let result = tokio::time::timeout(Duration::from_secs(35), session.call(&value))
            .await
            .map_err(|_| error("DDI operation deadline"));
        let cleanup = session
            .cleanup_input(session.cancel.load(Ordering::Acquire))
            .await;
        if let Err(e) = cleanup {
            let _ = session.close_ax().await;
            return Err(e);
        }
        match result {
            Ok(Ok(v)) => Ok(v),
            other => {
                // Abort semantic AX correlation after any failed operation.
                // Read-only recovery may reconnect; uncertain effects never replay.
                let _ = session.close_ax().await;
                let op = value["op"].as_str().unwrap_or("");
                if !["apps", "foreground", "snapshot", "clipboard_verify"].contains(&op) {
                    session.poisoned = true;
                }
                match other {
                    Ok(Err(e)) | Err(e) => Err(e),
                    _ => unreachable!(),
                }
            }
        }
    });
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
/// pocket_ddi_bytes_free using its exact returned length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_screenshot(
    handle: *mut PocketDDISession,
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
    let session = unsafe { &mut *handle };
    let result = run_sync_local(async {
        session.proceed()?;
        bounded(session.capture.take_screenshot(None, ImageFormat::Png)).await
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pocket_ddi_close(
    handle: *mut PocketDDISession,
    cancel: *mut PocketDDICancellation,
) -> *mut IdeviceFfiError {
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
    drop(session);
    match result {
        Ok(()) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        for refusal in [POINT_UNOBSERVED, FOREGROUND_NOT_OBSERVED, POINT_COVERED, POINT_UNCONFIRMED] {
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
