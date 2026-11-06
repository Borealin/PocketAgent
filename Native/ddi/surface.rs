//! Display evidence, not a pane selector. UUIDs stay native and never enter the
//! model/transcript. Window ownership still comes from the existing AX checks.
use super::{Geometry, Json, Value, json};

#[derive(Clone)]
pub(super) struct State {
    key: Value,
    pub(super) geometry: Option<Geometry>,
    pub(super) summary: Json,
}

impl PartialEq for State {
    fn eq(&self, other: &Self) -> bool { self.key == other.key && self.geometry == other.geometry }
}

impl State {
    pub(super) fn read(info: &Value) -> Self {
        let displays = info.as_dictionary().and_then(|d| d.get("displays")).and_then(Value::as_array);
        let orientation = info.as_dictionary().and_then(|d| d.get("orientation"))
            .and_then(Value::as_dictionary).and_then(|d| d.get("currentDeviceOrientation"))
            .and_then(Value::as_string).filter(|s| matches!(*s,
                "portrait" | "portraitUpsideDown" | "landscapeLeft" | "landscapeRight" | "faceUp" | "faceDown" | "unknown"));
        let mut state = Self { key: Value::Array(vec![]), geometry: None,
            summary: json!({"state":"unavailable","reason":"invalid_metadata",
                "display_count":0,"active_display_count":0,"device_orientation":orientation}) };
        let Some(displays) = displays.filter(|d| !d.is_empty() && d.len() <= 8) else { return state; };
        state.summary["display_count"] = json!(displays.len());
        let active: Vec<_> = displays.iter().filter(|v| v.as_dictionary().is_some_and(|d| {
            d.get("active").and_then(Value::as_boolean) == Some(true)
                || (displays.len() == 1 && !d.contains_key("active"))
        })).collect();
        state.summary["active_display_count"] = json!(active.len());
        let mut keys = vec![];
        for display in displays {
            let Some(d) = display.as_dictionary() else { return state; };
            // Keep the established single-display path when older metadata
            // omits optional identity/active fields; never infer a second surface.
            let id = d.get("uniqueId").and_then(Value::as_string).filter(|s| !s.is_empty() && s.len() <= 128);
            if (d.contains_key("uniqueId") && id.is_none()) || (displays.len() > 1 && id.is_none())
                || d.get("primary").and_then(Value::as_boolean).is_none()
                || d.get("active").is_some_and(|v| v.as_boolean().is_none()) { return state; }
            let mut key = plist::Dictionary::new();
            for k in ["uniqueId", "active", "primary", "nativeOrientation", "currentOrientation", "bounds", "pointScale", "nativeSize"] {
                if let Some(value) = d.get(k) { key.insert(k.into(), value.clone()); }
            }
            keys.push((id, Value::Dictionary(key)));
        }
        keys.sort_by_key(|(id, _)| *id);
        if keys.windows(2).any(|pair| pair[0].0.is_some() && pair[0].0 == pair[1].0) { return state; }
        // Ignore inventory order and unrelated timestamps/physical measurements.
        state.key = Value::Array(keys.into_iter().map(|(_, key)| key).collect());
        if active.len() != 1 {
            state.summary["reason"] = json!(if active.is_empty() { "no_active_display" } else { "ambiguous_active_display" });
            return state;
        }
        let d = active[0].as_dictionary().unwrap();
        let rotation = d.get("currentOrientation").and_then(Value::as_string)
            .filter(|s| matches!(*s, "rot0" | "rot90" | "rot180" | "rot270"));
        state.summary["rotation"] = json!(rotation);
        state.summary["active_display_is_primary"] = json!(d.get("primary").and_then(Value::as_boolean));
        if displays.len() != 1 {
            // Even one active display cannot bind AX display0, a window's local
            // frame, default HID or the default screenshot to its global region.
            state.summary["reason"] = json!("window_mapping_unverified");
            return state;
        }
        if rotation != Some("rot0") || d.get("nativeOrientation").and_then(Value::as_string) != Some("rot0") {
            state.summary["reason"] = json!("rotation_unverified");
            return state;
        }
        if let Ok(g) = Geometry::from(info) {
            if g.x == 0. && g.y == 0. && g.width > 0. && g.width < g.height && g.height.is_finite() {
                state.geometry = Some(g);
                state.summary["state"] = json!("single_display_portrait");
                state.summary["reason"] = json!("existing_ax_ownership_checks_required");
            }
        }
        state
    }

    pub(super) fn active_uuid(&self) -> Option<&str> {
        let mut active = self.key.as_array()?.iter().filter_map(Value::as_dictionary)
            .filter(|d| d.get("active").and_then(Value::as_boolean) == Some(true));
        let display = active.next()?;
        if active.next().is_some() { return None; }
        display.get("uniqueId").and_then(Value::as_string)
    }

    /// Reuse the verified typed descriptor association, for diagnostics only.
    /// A matched touchscreen does not establish App/window or AX coordinates.
    pub(super) fn record_touchscreen(&mut self, surfaces: Option<&[idevice::core_device::HidSurface]>) {
        let mut matches = vec![];
        if let (Some(uuid), Some(surfaces)) = (self.active_uuid(), surfaces) {
            for surface in surfaces {
                if !surface.product.as_deref().is_some_and(|p| p.starts_with("CoreDevice touchscreen(")) { continue; }
                let compact = surface.display_uuid.as_ref().and_then(Value::as_string);
                let stored = surface.codable_property_storage.as_ref().and_then(Value::as_dictionary).and_then(|d| d.get("displayUUID"))
                    .and_then(Value::as_dictionary).and_then(|d| d.get("string")).and_then(Value::as_string);
                let association = match (compact, stored) {
                    (Some(a), Some(b)) if a == b => Some(a), (Some(_), Some(_)) => None,
                    (Some(a), None) | (None, Some(a)) => Some(a), (None, None) => None,
                };
                if association == Some(uuid) && surface.service_id != 0 { matches.push(surface.service_id); }
            }
        }
        let status = if surfaces.is_none() { "probe_failed" } else {
            match matches.len() { 1 => "matched_unverified_coordinates", 0 => "unresolved", _ => "ambiguous" }
        };
        self.summary["touchscreen_association"] = json!(status);
        let previous = std::mem::replace(&mut self.key, Value::Array(vec![]));
        self.key = Value::Array(vec![previous, Value::Array(matches.into_iter().map(Value::from).collect())]);
    }

    pub(super) fn require(&self) -> Result<Geometry, &'static str> {
        self.geometry.ok_or("DDI control surface unavailable; display/window mapping is unverified")
    }

    pub(super) fn require_same(&self, observed: Option<&Self>) -> Result<(), &'static str> {
        self.require()?;
        if observed != Some(self) { return Err("DDI display changed or has no current surface observation"); }
        Ok(())
    }
    /// A focus tap consumes its snapshot before text chords. Keep text bound
    /// to current display state while coordinate/AX effects require that snapshot.
    pub(super) fn admit_effect(&self, op: &str, previous: Option<&Self>, observed: Option<&Self>) -> Result<(), &'static str> {
        self.require()?;
        if let Some(previous) = previous { self.require_same(Some(previous))?; }
        if matches!(op, "tap" | "hold" | "drag" | "surface_drag" | "ax_replace") { self.require_same(observed)?; }
        Ok(())
    }

}

#[cfg(test)]
mod tests {
    use super::*;
    fn info(id: &str) -> Value {
        super::super::archive::fields(&[("displays", Value::Array(vec![super::super::archive::fields(&[
            ("uniqueId",id.into()),("primary",true.into()),("active",true.into()),
            ("nativeOrientation","rot0".into()),("currentOrientation","rot0".into()),("pointScale",3u64.into()),
            ("bounds",Value::Array(vec![Value::Array(vec![0u64.into(),0u64.into()]),
                Value::Array(vec![1125u64.into(),2436u64.into()])])),
            ("nativeSize",Value::Array(vec![1125u64.into(),2436u64.into()])),
        ])]))])
    }
    #[test]
    fn only_one_active_primary_portrait_is_admitted_without_pane_guesses() {
        let good = info("display-a");
        assert!(State::read(&good).require().is_ok());
        let state = State::read(&good);
        for op in ["tap", "hold", "drag", "surface_drag", "ax_replace"] {
            assert!(state.admit_effect(op,Some(&state),None).is_err());
            assert!(state.admit_effect(op,Some(&state),Some(&state)).is_ok());
        }
        for op in ["clear", "paste", "key", "keys", "clipboard_set", "activate", "home"] {
            assert!(state.admit_effect(op,Some(&state),None).is_ok());
        }
        let mut legacy = good.clone();
        let d = legacy.as_dictionary_mut().unwrap().get_mut("displays").unwrap().as_array_mut().unwrap()[0].as_dictionary_mut().unwrap();
        d.remove("active"); d.remove("uniqueId");
        assert!(State::read(&legacy).require().is_ok());
        for (key, value, reason) in [("active", false.into(), "no_active_display"),
            ("primary", false.into(), "invalid_metadata"),
            ("currentOrientation", "rot270".into(), "rotation_unverified")] {
            let mut changed = good.clone();
            changed.as_dictionary_mut().unwrap().get_mut("displays").unwrap().as_array_mut().unwrap()[0]
                .as_dictionary_mut().unwrap().insert(key.into(), value);
            let s = State::read(&changed); assert!(s.require().is_err()); assert_eq!(s.summary["reason"],reason);
        }
        let mut dual = good.clone();
        let mut inner = info("display-b").as_dictionary().unwrap()["displays"].as_array().unwrap()[0].clone();
        inner.as_dictionary_mut().unwrap().insert("primary".into(),false.into());
        dual.as_dictionary_mut().unwrap().get_mut("displays").unwrap().as_array_mut().unwrap().push(inner);
        assert_eq!(State::read(&dual).summary["reason"],"ambiguous_active_display");
        dual.as_dictionary_mut().unwrap().get_mut("displays").unwrap().as_array_mut().unwrap()[0]
            .as_dictionary_mut().unwrap().insert("active".into(),false.into());
        assert_eq!(State::read(&dual).summary["reason"],"window_mapping_unverified");
        let mut state = State::read(&dual);
        // Unknown optional diagnostic shapes must not break the shared HID
        // list decoder used by ordinary keyboard preparation.
        let raw = super::super::archive::fields(&[("_ServiceID",42u64.into()),
            ("displayUUID",Value::Array(vec![1u64.into()])),
            ("_CoreDevice_codablePropertyStorage",false.into())]);
        let decoded: idevice::core_device::HidSurface = plist::from_value(&raw).unwrap();
        assert_eq!(decoded.service_id,42);
        let surface = idevice::core_device::HidSurface { service_id: 42,
            product: Some("CoreDevice touchscreen(test)".into()), primary_usage: Some(4), primary_usage_page: Some(13),
            display_uuid: Some("display-b".into()), codable_property_storage: None };
        state.record_touchscreen(Some(&[surface.clone()]));
        assert_eq!(state.summary["touchscreen_association"],"matched_unverified_coordinates");
        assert!(state.require().is_err()); // Matching HID never authorizes an inner action.
        for op in ["tap", "ax_replace", "clear", "paste", "key", "keys", "clipboard_set", "activate", "home"] {
            assert!(state.admit_effect(op,None,None).is_err());
        }
        let mut ambiguous = State::read(&dual);
        ambiguous.record_touchscreen(Some(&[surface.clone(),surface]));
        assert_eq!(ambiguous.summary["touchscreen_association"],"ambiguous");
        assert!(ambiguous.require().is_err());
    }
    #[test]
    fn equal_size_display_replacement_invalidates_old_coordinates_and_summary_omits_identifiers() {
        let old = State::read(&info("display-a")); let current = State::read(&info("display-b"));
        assert!(current.require_same(Some(&old)).is_err());
        assert!(current.admit_effect("paste",Some(&old),None).is_err());
        assert!(current.require_same(None).is_err());
        assert!(current.require_same(Some(&current)).is_ok());
        assert!(!current.summary.to_string().contains("display-b"));
        let mut unrelated = info("display-b");
        unrelated.as_dictionary_mut().unwrap().insert("timestamp".into(), 42u64.into());
        unrelated.as_dictionary_mut().unwrap().insert("orientation".into(), super::super::archive::fields(&[("currentDeviceOrientation","faceUp".into())]));
        assert!(State::read(&unrelated).require_same(Some(&current)).is_ok());
    }
}
