//! Narrow, profile-locked primitives for the physically verified inner Duo display.
//! This module does not infer app/window ownership or support other poses.

use idevice::IdeviceError;
use plist::Value;

pub(crate) const PROFILE: &str = "DDI Duo profile unsupported";
pub(crate) const DISPLAY: &str = "DDI Duo active display unavailable or ambiguous";
pub(crate) const SERVICE: &str = "DDI Duo touchscreen service unavailable or ambiguous";
pub(crate) const WIDTH: f64 = 469.0;
pub(crate) const HEIGHT: f64 = 669.0;

pub(crate) fn device_eligible(properties: &std::collections::HashMap<String, Value>) -> bool {
    properties.get("ProductType").and_then(Value::as_string) == Some("iPhone19,4")
        && properties.get("BuildVersion").and_then(Value::as_string) == Some("24C5037i")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Pane {
    Left,
    Right,
}

impl Pane {
    pub(crate) fn parse(value: &str) -> Result<Self, IdeviceError> {
        match value {
            "left" => Ok(Self::Left),
            "right" => Ok(Self::Right),
            _ => Err(error("DDI Duo pane must be left or right")),
        }
    }
    pub(crate) fn app(self) -> &'static str {
        match self {
            Self::Left => "duo-pane-left",
            Self::Right => "duo-pane-right",
        }
    }
    pub(crate) fn origin(self) -> f64 {
        if self == Self::Left { 0.0 } else { 482.0 }
    }
}

pub(crate) fn select_active_display(displays: &[Value]) -> Result<&Value, IdeviceError> {
    let mut active = displays.iter().filter(|d| {
        dict(d)
            .and_then(|d| d.get("active"))
            .and_then(Value::as_boolean)
            == Some(true)
    });
    let display = active.next().ok_or_else(|| error(DISPLAY))?;
    if active.next().is_some() {
        return Err(error(DISPLAY));
    }
    let d = dict(display).ok_or_else(|| error(PROFILE))?;
    let id = d
        .get("uniqueId")
        .and_then(Value::as_string)
        .filter(|s| !s.is_empty());
    let is_profile = id.is_some()
        && d.get("nativeSize")
            .and_then(Value::as_array)
            .is_some_and(|a| nums(a) == Some([1878., 2670.]))
        && d.get("bounds")
            .and_then(Value::as_array)
            .is_some_and(|a| bounds(a) == Some([0., 0., 2007., 2853.]))
        && d.get("pointScale").and_then(number) == Some(3.)
        && d.get("nativeOrientation").and_then(Value::as_string) == Some("rot0")
        && d.get("currentOrientation").and_then(Value::as_string) == Some("rot90");
    if !is_profile {
        return Err(error(PROFILE));
    }
    Ok(display)
}

pub(crate) fn select_touchscreen_service<'a>(
    surfaces: &'a [idevice::core_device::HidSurface],
    display_id: &str,
) -> Result<u64, IdeviceError> {
    let mut matches = surfaces.iter().filter(|s| {
        s.product
            .as_deref()
            .is_some_and(|p| p.starts_with("CoreDevice touchscreen("))
            && descriptor_display_uuid(s) == Some(display_id)
    });
    let id = matches
        .next()
        .map(|s| s.service_id)
        .filter(|id| *id != 0)
        .ok_or_else(|| error(SERVICE))?;
    if matches.next().is_some() {
        return Err(error(SERVICE));
    }
    Ok(id)
}

fn descriptor_display_uuid(surface: &idevice::core_device::HidSurface) -> Option<&str> {
    let compact = surface.display_uuid.as_deref();
    let stored = surface
        .codable_property_storage
        .as_ref()
        .and_then(|storage| storage.get("displayUUID"))
        .and_then(Value::as_dictionary)
        .and_then(|typed| typed.get("string"))
        .and_then(Value::as_string);
    match (compact, stored) {
        (Some(a), Some(b)) if a == b => Some(a),
        (Some(_), Some(_)) => None,
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    }
}

/// Pane-local logical points (469x669) -> native normalized (v, 1-u).
pub(crate) fn native_point(pane: Pane, x: f64, y: f64) -> Result<(u16, u16), IdeviceError> {
    if !x.is_finite() || !y.is_finite() || x < 0. || y < 0. || x >= WIDTH || y >= HEIGHT {
        return Err(error("DDI Duo point outside pane"));
    }
    let u = (pane.origin() + x) / 951.0;
    let v = y / HEIGHT;
    Ok((
        (v * 65535.0).round() as u16,
        ((1.0 - u) * 65535.0).round() as u16,
    ))
}

/// Captured 58-byte Device Hub DigitizerReport edge sample. `edgeQuarter=1`
/// is native-left. Touch and range flags vary by sample; edge flags remain on lift.
pub(crate) fn edge_report(
    x: u16,
    y: u16,
    touching: bool,
    in_range: bool,
    timestamp: u64,
) -> Vec<u8> {
    let mut b = vec![0u8; 58];
    b[0] = 9;
    b[1] = 1;
    b[2] = 5;
    b[3] = 0x02 | if touching { 0x40 } else { 0 } | if in_range { 0x80 } else { 0 };
    b[4..6].copy_from_slice(&x.to_le_bytes());
    b[6..8].copy_from_slice(&y.to_le_bytes());
    b[40] = 2;
    b[45..53].copy_from_slice(&timestamp.to_le_bytes());
    b[429 / 8] |= 1 << (429 % 8); // locked
    b[444 / 8] |= 1 << (444 % 8); // native-left
    b
}

/// Captured ordinary 58-byte DigitizerReport shape used by ipb's physical Duo
/// path. Unlike idevice's generic builder, this has identity/max count 1 and no
/// timestamp; the service ID is supplied separately to `send_report`.
pub(crate) fn touch_report(x: u16, y: u16, touching: bool, in_range: bool) -> Vec<u8> {
    let mut b = vec![0u8; 58];
    b[0] = 9;
    b[1] = 1;
    b[2] = 1;
    b[3] = (if touching { 0x40 } else { 0 }) | (if in_range { 0x80 } else { 0 });
    b[4..6].copy_from_slice(&x.to_le_bytes());
    b[6..8].copy_from_slice(&y.to_le_bytes());
    b
}

pub(crate) fn mach_timestamp() -> u64 {
    #[cfg(target_vendor = "apple")]
    unsafe {
        unsafe extern "C" { fn mach_absolute_time() -> u64; }
        mach_absolute_time()
    }
    #[cfg(not(target_vendor = "apple"))]
    { 1 }
}

fn dict(v: &Value) -> Option<&plist::Dictionary> {
    v.as_dictionary()
}
fn number(v: &Value) -> Option<f64> {
    v.as_real()
        .or_else(|| v.as_unsigned_integer().map(|v| v as f64))
        .or_else(|| v.as_signed_integer().map(|v| v as f64))
}
fn nums(a: &[Value]) -> Option<[f64; 2]> {
    if a.len() != 2 {
        return None;
    }
    Some([number(a.first()?)?, number(a.get(1)?)?])
}
fn bounds(a: &[Value]) -> Option<[f64; 4]> {
    if a.len() != 2 || a.iter().any(|v| v.as_array().is_none_or(|a| a.len() != 2)) {
        return None;
    }
    Some([
        number(a.get(0)?.as_array()?.first()?)?,
        number(a.get(0)?.as_array()?.get(1)?)?,
        number(a.get(1)?.as_array()?.first()?)?,
        number(a.get(1)?.as_array()?.get(1)?)?,
    ])
}
fn error(message: &'static str) -> IdeviceError {
    IdeviceError::UnexpectedResponse(message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use plist::Value;

    #[test]
    fn maps_pane_edges_to_verified_native_pose() {
        assert_eq!(native_point(Pane::Left, 0., 0.).unwrap(), (0, 65535));
        assert_eq!(native_point(Pane::Right, 0., 0.).unwrap(), (0, 32320));
        assert_eq!(native_point(Pane::Right, 468., 668.).unwrap(), (65437, 69));
        assert!(native_point(Pane::Right, 469., 0.).is_err());
    }

    #[test]
    fn duo_digitizer_reports_keep_the_captured_ordinary_and_edge_shapes() {
        let ordinary_down = touch_report(0x1234, 0xabcd, true, true);
        let ordinary_up = touch_report(0x1234, 0xabcd, false, false);
        assert_eq!(ordinary_down.len(), 58);
        assert_eq!(
            &ordinary_down[..8],
            &[9, 1, 1, 0xc0, 0x34, 0x12, 0xcd, 0xab]
        );
        assert!(ordinary_down[8..].iter().all(|b| *b == 0));
        assert_eq!(ordinary_up[3], 0);
        assert!(ordinary_up[8..].iter().all(|b| *b == 0));

        let down = edge_report(0x1234, 0xabcd, true, true, 0x0708010203040506);
        let up = edge_report(0x1234, 0xabcd, false, false, 0x0708010203040506);
        assert_eq!(down.len(), 58);
        assert_eq!(&down[..8], &[9, 1, 5, 0xc2, 0x34, 0x12, 0xcd, 0xab]);
        assert_eq!(down[40], 2);
        assert_eq!(&down[45..53], &[6, 5, 4, 3, 2, 1, 8, 7]);
        assert_eq!(down[53] & 0x20, 0x20);
        assert_eq!(down[55] & 0x10, 0x10);
        assert_eq!(up[3], 0x02);
        assert_eq!(up[53], down[53]);
        assert_eq!(up[55], down[55]);
    }

    #[test]
    fn chooses_only_one_active_verified_display() {
        let mut properties = std::collections::HashMap::new();
        assert!(!device_eligible(&properties));
        properties.insert("ProductType".into(), "iPhone19,4".into());
        properties.insert("BuildVersion".into(), "24C5037i".into());
        assert!(device_eligible(&properties));
        properties.insert("BuildVersion".into(), "unknown".into());
        assert!(!device_eligible(&properties));
        let mut d = plist::Dictionary::new();
        d.insert("active".into(), Value::Boolean(true));
        d.insert("uniqueId".into(), Value::String("opaque".into()));
        d.insert(
            "nativeSize".into(),
            Value::Array(vec![
                Value::Integer(1878.into()),
                Value::Integer(2670.into()),
            ]),
        );
        d.insert(
            "bounds".into(),
            Value::Array(vec![
                Value::Array(vec![0.into(), 0.into()]),
                Value::Array(vec![2007.into(), 2853.into()]),
            ]),
        );
        d.insert("pointScale".into(), Value::Integer(3.into()));
        d.insert("nativeOrientation".into(), Value::String("rot0".into()));
        d.insert("currentOrientation".into(), Value::String("rot90".into()));
        let one = Value::Dictionary(d);
        assert!(select_active_display(&[one.clone()]).is_ok());
        assert!(select_active_display(&[one.clone(), one.clone()]).is_err());
        let mut malformed = match one.clone() {
            Value::Dictionary(d) => d,
            _ => unreachable!(),
        };
        malformed.insert(
            "nativeSize".into(),
            Value::Array(vec![1878.into(), 2670.into(), 1.into()]),
        );
        assert!(select_active_display(&[Value::Dictionary(malformed)]).is_err());
    }

    #[test]
    fn selects_touchscreen_by_typed_display_association_only() {
        fn surface(id: u64, product: &str, display: &str) -> idevice::core_device::HidSurface {
            let mut typed_fields = plist::Dictionary::new();
            typed_fields.insert("string".into(), Value::String(display.into()));
            let typed = Value::Dictionary(typed_fields);
            let mut storage = plist::Dictionary::new();
            storage.insert("displayUUID".into(), typed);
            idevice::core_device::HidSurface {
                service_id: id,
                product: Some(product.into()),
                primary_usage: Some(4),
                primary_usage_page: Some(13),
                display_uuid: None,
                codable_property_storage: Some(storage),
            }
        }
        let surfaces = [
            surface(257, "CoreDevice touchscreen(outer)", "outer"),
            surface(258, "CoreDevice touchscreen(inner)", "inner"),
            surface(512, "CoreDevice keyboard", "inner"),
        ];
        assert_eq!(select_touchscreen_service(&surfaces, "inner").unwrap(), 258);
        assert!(select_touchscreen_service(&surfaces, "missing").is_err());
        let ambiguous = [
            surfaces[0].clone(),
            surfaces[1].clone(),
            surfaces[1].clone(),
        ];
        assert!(select_touchscreen_service(&ambiguous, "inner").is_err());
    }
}
