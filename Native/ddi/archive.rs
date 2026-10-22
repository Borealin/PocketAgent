// AX archive dialect adapted from ipb's MIT-licensed ax_archive.py.
// Copyright (c) 2026 Borealin and ipbtools contributors. See ipb-LICENSE.txt.
// Only property-list data is decoded; no Objective-C classes are instantiated.
use plist::{Dictionary, Uid, Value};
use std::{
    collections::{HashMap, HashSet},
    io::Cursor,
};

pub const MAX_BYTES: usize = 20 * 1024 * 1024;
pub fn dict(entries: impl IntoIterator<Item = (String, Value)>) -> Value {
    Value::Dictionary(entries.into_iter().collect())
}
pub fn fields(entries: &[(&str, Value)]) -> Value {
    dict(entries.iter().map(|(k, v)| (k.to_string(), v.clone())))
}
fn invalid(message: &str) -> String {
    format!("Invalid AX archive: {message}")
}

pub fn decode(bytes: &[u8]) -> Result<Value, String> {
    if bytes.len() > MAX_BYTES {
        return Err(invalid("size limit"));
    }
    let archive = Value::from_reader(Cursor::new(bytes)).map_err(|_| invalid("property list"))?;
    let a = archive.as_dictionary().ok_or_else(|| invalid("root"))?;
    if a.get("$archiver").and_then(Value::as_string) != Some("NSKeyedArchiver") {
        return Err(invalid("archiver"));
    }
    let objects = a
        .get("$objects")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("objects"))?;
    if objects.is_empty() || objects.len() > 50_000 {
        return Err(invalid("object limit"));
    }
    let root = a
        .get("$top")
        .and_then(Value::as_dictionary)
        .and_then(|d| d.get("root"))
        .ok_or_else(|| invalid("top"))?;
    Decoder {
        objects,
        memo: HashMap::new(),
        visiting: HashSet::new(),
        steps: 0,
        expanded: 0,
    }
    .value(root, 0)
}
struct Decoder<'a> {
    objects: &'a [Value],
    memo: HashMap<usize, (Value, usize)>,
    visiting: HashSet<usize>,
    steps: usize,
    expanded: usize,
}
fn expanded_size(v: &Value, depth: usize) -> Result<usize, String> {
    if depth > 100 {
        return Err(invalid("expansion depth"));
    }
    let mut size = 64usize;
    if let Some(s) = v.as_string() {
        size += s.len();
    }
    if let Some(d) = v.as_data() {
        size += d.len();
    }
    if let Some(a) = v.as_array() {
        for v in a {
            size = size
                .checked_add(expanded_size(v, depth + 1)?)
                .ok_or_else(|| invalid("expansion overflow"))?;
            if size > 40 * 1024 * 1024 {
                return Err(invalid("expansion size"));
            }
        }
    }
    if let Some(d) = v.as_dictionary() {
        for (k, v) in d {
            size = size
                .checked_add(k.len() + expanded_size(v, depth + 1)?)
                .ok_or_else(|| invalid("expansion overflow"))?;
            if size > 40 * 1024 * 1024 {
                return Err(invalid("expansion size"));
            }
        }
    }
    Ok(size)
}
impl Decoder<'_> {
    fn charge(&mut self, size: usize) -> Result<(), String> {
        self.expanded = self
            .expanded
            .checked_add(size)
            .ok_or_else(|| invalid("expansion overflow"))?;
        if self.expanded > 40 * 1024 * 1024 {
            return Err(invalid("expansion budget"));
        }
        Ok(())
    }
    fn value(&mut self, v: &Value, depth: usize) -> Result<Value, String> {
        self.steps += 1;
        if depth > 100 || self.steps > 100_000 {
            return Err(invalid("nesting/work limit"));
        }
        if let Some(uid) = v.as_uid() {
            let i = usize::try_from(uid.get()).map_err(|_| invalid("UID range"))?;
            if i == 0 {
                return Ok(Value::Uid(Uid::new(0)));
            }
            if let Some((_, size)) = self.memo.get(&i) {
                let size = *size;
                self.charge(size)?;
                return Ok(self.memo[&i].0.clone());
            }
            let item = self.objects.get(i).ok_or_else(|| invalid("UID range"))?;
            if !self.visiting.insert(i) {
                return Err(invalid("cycle"));
            }
            let result = self.value(item, depth + 1)?;
            self.visiting.remove(&i);
            let size = expanded_size(&result, 0)?;
            self.charge(size)?;
            self.memo.insert(i, (result.clone(), size));
            return Ok(result);
        }
        if let Some(items) = v.as_array() {
            return items
                .iter()
                .map(|v| self.value(v, depth + 1))
                .collect::<Result<Vec<_>, _>>()
                .map(Value::Array);
        }
        let Some(d) = v.as_dictionary() else {
            self.charge(expanded_size(v, 0)?)?;
            return Ok(v.clone());
        };
        let class = match d.get("$class") {
            Some(c) => self
                .value(c, depth + 1)?
                .as_dictionary()
                .and_then(|c| c.get("$classname"))
                .and_then(Value::as_string)
                .map(str::to_owned),
            None => None,
        };
        if let Some(keys) = d.get("NS.keys") {
            let keys = self.value(keys, depth + 1)?;
            let values = self.value(
                d.get("NS.objects").ok_or_else(|| invalid("dict values"))?,
                depth + 1,
            )?;
            let keys = keys.as_array().ok_or_else(|| invalid("dict keys"))?;
            let values = values.as_array().ok_or_else(|| invalid("dict values"))?;
            if keys.len() != values.len() {
                return Err(invalid("dict length"));
            }
            let mut result = Dictionary::new();
            for (k, v) in keys.iter().zip(values) {
                let k = if let Some(k) = k.as_string() {
                    k.to_owned()
                } else if let Some(k) = k.as_unsigned_integer() {
                    k.to_string()
                } else {
                    return Err(invalid("dict key"));
                };
                self.charge(expanded_size(v, 0)?)?;
                if result.insert(k, v.clone()).is_some() {
                    return Err(invalid("duplicate key"));
                }
            }
            return Ok(Value::Dictionary(result));
        }
        if matches!(class.as_deref(), Some("NSArray" | "NSMutableArray")) {
            return self.value(
                d.get("NS.objects").ok_or_else(|| invalid("array"))?,
                depth + 1,
            );
        }
        if matches!(class.as_deref(), Some("NSData" | "NSMutableData")) {
            return self.value(d.get("NS.data").ok_or_else(|| invalid("data"))?, depth + 1);
        }
        if matches!(
            class.as_deref(),
            Some(
                "NSString" | "NSMutableString" | "NSAttributedString" | "NSMutableAttributedString"
            )
        ) {
            if let Some(s) = d.get("NSString").or_else(|| d.get("NS.string")) {
                return self.value(s, depth + 1);
            }
        }
        if class.as_deref() == Some("NSValue") {
            if let Some(r) = d.get("NS.rectval") {
                let text = self.value(r, depth + 1)?;
                let text = text.as_string().ok_or_else(|| invalid("rect string"))?;
                let numbers = text
                    .split(|c: char| c == '{' || c == '}' || c == ',' || c.is_whitespace())
                    .filter(|s| !s.is_empty())
                    .map(str::parse::<f64>)
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|_| invalid("rect numbers"))?;
                if numbers == [f64::INFINITY, f64::INFINITY, 0.0, 0.0] {
                    return Ok(fields(&[("unavailable", "CGRectNull".into())]));
                }
                if numbers.len() != 4
                    || !numbers.iter().all(|n| n.is_finite())
                    || numbers[2] < 0.0
                    || numbers[3] < 0.0
                {
                    return Err(invalid("rect bounds"));
                }
                return Ok(dict(
                    ["x", "y", "width", "height"]
                        .iter()
                        .zip(numbers)
                        .map(|(k, n)| (k.to_string(), Value::Real(n))),
                ));
            }
        }
        let mut result = Dictionary::new();
        for (k, v) in d {
            if k != "$class" {
                result.insert(k.clone(), self.value(v, depth + 1)?);
            }
        }
        Ok(Value::Dictionary(result))
    }
}

struct Encoder {
    objects: Vec<Value>,
    classes: HashMap<String, Value>,
}
impl Encoder {
    fn add(&mut self, v: Value) -> Value {
        self.objects.push(v);
        Value::Uid(Uid::new((self.objects.len() - 1) as u64))
    }
    fn class(&mut self, name: &str) -> Value {
        if let Some(v) = self.classes.get(name) {
            return v.clone();
        }
        let v = self.add(fields(&[
            ("$classname", name.into()),
            (
                "$classes",
                Value::Array(vec![name.into(), "NSObject".into()]),
            ),
        ]));
        self.classes.insert(name.into(), v.clone());
        v
    }
    fn encode(&mut self, v: &Value) -> Value {
        if v.as_uid().is_some_and(|u| u.get() == 0) {
            return Value::Uid(Uid::new(0));
        }
        if let Some(d) = v.as_dictionary() {
            let keys = Value::Array(
                d.keys()
                    .map(|k| self.encode(&Value::String(k.clone())))
                    .collect(),
            );
            let values = Value::Array(d.values().map(|v| self.encode(v)).collect());
            let class = self.class("NSDictionary");
            return self.add(fields(&[
                ("NS.keys", keys),
                ("NS.objects", values),
                ("$class", class),
            ]));
        }
        if let Some(a) = v.as_array() {
            let values = Value::Array(a.iter().map(|v| self.encode(v)).collect());
            let class = self.class("NSArray");
            return self.add(fields(&[("NS.objects", values), ("$class", class)]));
        }
        if let Some(data) = v.as_data() {
            let class = self.class("NSData");
            return self.add(fields(&[
                ("NS.data", Value::Data(data.to_vec())),
                ("$class", class),
            ]));
        }
        self.add(v.clone())
    }
    fn token(&mut self, v: &Value) -> Result<Value, String> {
        let d = v.as_dictionary().ok_or_else(|| invalid("translation"))?;
        let mut result = Dictionary::new();
        for k in ["rawElementData", "bridgeDelegateToken", "objectID"] {
            let value = match d.get(k) {
                Some(v) => self.encode(v),
                None => Value::Uid(Uid::new(0)),
            };
            result.insert(k.into(), value);
        }
        for k in ["pid", "isApplicationElement", "didPopuldateAppInfo"] {
            result.insert(
                k.into(),
                d.get(k).cloned().unwrap_or_else(|| {
                    if k == "pid" {
                        0u64.into()
                    } else {
                        false.into()
                    }
                }),
            );
        }
        result.insert("$class".into(), self.class("AXPTranslationObject"));
        Ok(self.add(Value::Dictionary(result)))
    }
}
pub fn request(kind: u64, parameters: Value, token: Option<&Value>) -> Result<Vec<u8>, String> {
    if ![1, 5, 6, 8].contains(&kind) {
        return Err(invalid("request kind"));
    }
    if kind == 8 {
        let p = parameters
            .as_dictionary()
            .ok_or_else(|| invalid("set value parameters"))?;
        if p.len() != 1 || p.get("value").and_then(Value::as_string).is_none() {
            return Err(invalid("set value requires one NSString value"));
        }
        let t = token
            .and_then(Value::as_dictionary)
            .ok_or_else(|| invalid("set value token"))?;
        if t.get("pid")
            .and_then(Value::as_unsigned_integer)
            .filter(|n| *n > 0)
            .is_none()
            || t.get("objectID")
                .and_then(Value::as_unsigned_integer)
                .is_none()
        {
            return Err(invalid("set value token identity"));
        }
    }
    let mut e = Encoder {
        objects: vec!["$null".into()],
        classes: HashMap::new(),
    };
    let params = if kind == 6 {
        let point = parameters.as_string().ok_or_else(|| invalid("point"))?;
        let string = e.encode(&point.into());
        let class = e.class("NSValue");
        let point = e.add(fields(&[
            ("NS.pointval", string),
            ("NS.special", 1u64.into()),
            ("$class", class),
        ]));
        let keys = Value::Array(vec![
            e.encode(&"point".into()),
            e.encode(&"displayId".into()),
        ]);
        let values = Value::Array(vec![point, e.encode(&0u64.into())]);
        let class = e.class("NSDictionary");
        e.add(fields(&[
            ("NS.keys", keys),
            ("NS.objects", values),
            ("$class", class),
        ]))
    } else {
        e.encode(&parameters)
    };
    let translation = if kind == 6 {
        e.token(&fields(&[("objectID", 1u64.into())]))?
    } else {
        match token {
            Some(v) => e.token(v)?,
            None => Value::Uid(Uid::new(0)),
        }
    };
    let class = e.class("AXPTranslatorRequest");
    let root = e.add(fields(&[
        ("requestType", kind.into()),
        ("clientType", 0u64.into()),
        ("actionType", 0u64.into()),
        (
            "attributeType",
            if kind == 8 { 53u64.into() } else { 0u64.into() },
        ),
        ("translation", translation),
        ("parameters", params),
        ("$class", class),
    ]));
    let archive = fields(&[
        ("$version", 100000u64.into()),
        ("$archiver", "NSKeyedArchiver".into()),
        ("$top", fields(&[("root", root)])),
        ("$objects", Value::Array(e.objects)),
    ]);
    let mut bytes = Vec::new();
    archive
        .to_writer_binary(&mut bytes)
        .map_err(|_| invalid("encode"))?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_round_trip_keeps_64_bit_tokens() {
        let token = fields(&[
            ("pid", 42u64.into()),
            ("objectID", u64::MAX.into()),
            ("isApplicationElement", true.into()),
        ]);
        let bytes = request(
            5,
            fields(&[("attributes", Value::Array(vec![8u64.into(), 21u64.into()]))]),
            Some(&token),
        )
        .unwrap();
        let decoded = decode(&bytes).unwrap();
        let d = decoded.as_dictionary().unwrap();
        assert_eq!(
            d["translation"].as_dictionary().unwrap()["objectID"].as_unsigned_integer(),
            Some(u64::MAX)
        );
        assert_eq!(
            d["parameters"].as_dictionary().unwrap()["attributes"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }
    #[test]
    fn set_text_encodes_only_value_attribute_and_observed_token() {
        let token = fields(&[("pid", 42u64.into()), ("objectID", u64::MAX.into())]);
        let decoded = decode(&request(8, fields(&[("value", "hello 世界".into())]), Some(&token)).unwrap()).unwrap();
        let d = decoded.as_dictionary().unwrap();
        assert_eq!(d["requestType"].as_unsigned_integer(), Some(8));
        assert_eq!(d["attributeType"].as_unsigned_integer(), Some(53));
        assert_eq!(
            d["parameters"].as_dictionary().unwrap()["value"].as_string(),
            Some("hello 世界")
        );
        assert_eq!(
            d["translation"].as_dictionary().unwrap()["objectID"].as_unsigned_integer(),
            Some(u64::MAX)
        );
        assert!(
            request(
                8,
                fields(&[("value", "x".into()), ("other", "y".into())]),
                Some(&token)
            )
            .is_err()
        );
        assert!(request(8, fields(&[("value", "x".into())]), None).is_err());
        assert!(request(8, fields(&[("value", Value::Data(vec![1]))]), Some(&token)).is_err());
        assert!(request(9, fields(&[]), Some(&token)).is_err());
    }
    #[test]
    fn rejects_invalid_and_cyclic_uids() {
        for uid in [1, 99] {
            let a = fields(&[
                ("$archiver", "NSKeyedArchiver".into()),
                (
                    "$objects",
                    Value::Array(vec!["$null".into(), Value::Uid(Uid::new(1))]),
                ),
                ("$top", fields(&[("root", Value::Uid(Uid::new(uid)))])),
            ]);
            let mut bytes = vec![];
            a.to_writer_binary(&mut bytes).unwrap();
            assert!(decode(&bytes).is_err());
        }
    }
    #[test]
    fn translation_null_references_remain_null() {
        let null = Value::Uid(Uid::new(0));
        let token = fields(&[
            ("pid", 42u64.into()),
            ("objectID", 7u64.into()),
            ("rawElementData", null.clone()),
            ("bridgeDelegateToken", null),
        ]);
        let bytes = request(
            5,
            fields(&[("attributes", Value::Array(vec![8u64.into()]))]),
            Some(&token),
        )
        .unwrap();
        let decoded = decode(&bytes).unwrap();
        let token = decoded.as_dictionary().unwrap()["translation"]
            .as_dictionary()
            .unwrap();
        for key in ["rawElementData", "bridgeDelegateToken"] {
            assert_eq!(token[key].as_uid().unwrap().get(), 0);
        }
    }
    #[test]
    fn rejects_reference_expansion_before_unbounded_cloning() {
        let a = fields(&[
            ("$archiver", "NSKeyedArchiver".into()),
            (
                "$objects",
                Value::Array(vec![
                    "$null".into(),
                    Value::Data(vec![0; 32 * 1024]),
                    Value::Array(vec![Value::Uid(Uid::new(1)); 4096]),
                ]),
            ),
            ("$top", fields(&[("root", Value::Uid(Uid::new(2)))])),
        ]);
        let mut bytes = vec![];
        a.to_writer_binary(&mut bytes).unwrap();
        assert!(decode(&bytes).is_err());
    }
}
