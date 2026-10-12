// Read-only AXP requests; protocol dialect from MIT ipb (see ipb-LICENSE.txt).
use super::archive::{self, MAX_BYTES, fields};
use idevice::{
    ReadWrite,
    dvt::message::{Aux, AuxValue, Message, MessageHeader, PayloadHeader},
};
use plist::Value;
use std::{
    collections::{HashSet, VecDeque},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub struct Ax {
    stream: Box<dyn ReadWrite>,
    next: u32,
    bytes: usize,
    subscribed: bool,
}
struct Incoming {
    id: u32,
    conversation: u32,
    needs_reply: bool,
    data: Option<Value>,
    args: Vec<Value>,
}
fn u32_at(bytes: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(
        bytes
            .get(at..at + 4)
            .ok_or("Short DTX integer")?
            .try_into()
            .map_err(|_| "Short DTX integer")?,
    ))
}
fn arguments(bytes: &[u8]) -> Result<Vec<Value>, String> {
    if bytes.is_empty() {
        return Ok(vec![]);
    }
    if bytes.len() < 16 {
        return Err("Short DTX aux".into());
    }
    let mut at = 16;
    let mut result = vec![];
    while at < bytes.len() {
        let kind = u32_at(bytes, at)? & 255;
        at += 4;
        match kind {
            10 => {}
            1 | 2 => {
                let len = u32_at(bytes, at)? as usize;
                at += 4;
                let value = bytes
                    .get(at..at.checked_add(len).ok_or("DTX aux overflow")?)
                    .ok_or("Short DTX aux data")?;
                result.push(if kind == 2 {
                    archive::decode(value)?
                } else {
                    String::from_utf8(value.to_vec())
                        .map_err(|_| "DTX string")?
                        .into()
                });
                at += len;
            }
            3 => {
                result.push(Value::Integer(u32_at(bytes, at)?.into()));
                at += 4;
            }
            6 | 9 => {
                let raw: [u8; 8] = bytes
                    .get(at..at + 8)
                    .ok_or("Short DTX primitive")?
                    .try_into()
                    .map_err(|_| "Short DTX primitive")?;
                result.push(if kind == 6 {
                    Value::Integer(i64::from_le_bytes(raw).into())
                } else {
                    let n = f64::from_le_bytes(raw);
                    if !n.is_finite() {
                        return Err("Non-finite DTX primitive".into());
                    }
                    Value::Real(n)
                });
                at += 8;
            }
            _ => return Err("Unsupported DTX aux type".into()),
        }
        if result.len() > 16 {
            return Err("DTX argument limit".into());
        }
    }
    Ok(result)
}
impl Ax {
    pub async fn new(stream: Box<dyn ReadWrite>) -> Result<Self, String> {
        let mut ax = Self {
            stream,
            next: 1,
            bytes: 0,
            subscribed: false,
        };
        let setup = tokio::time::timeout(Duration::from_secs(6), async {
            let id = ax.invoke("deviceAPIVersion", vec![]).await?;
            let api = ax.ack(id).await?;
            if api.as_ref().and_then(Value::as_unsigned_integer) != Some(26) {
                return Err("Unsupported AX device API (expected 26)".to_string());
            }
            // Record ownership before sending, including unconfirmed subscribe.
            ax.subscribed = true;
            let id = ax
                .invoke(
                    "clientNeedsAccessibility:",
                    vec![AuxValue::archived_value(true)],
                )
                .await?;
            ax.ack(id).await?;
            Ok(())
        })
        .await
        .map_err(|_| "AX setup timed out".to_string())
        .and_then(|r| r);
        if let Err(e) = setup {
            // Keep the owner alive after a deadline so unsubscribe is attempted
            // before this socket is dropped.
            let _ = tokio::time::timeout(Duration::from_secs(2), ax.close()).await;
            return Err(e);
        }
        Ok(ax)
    }
    async fn invoke(&mut self, name: &str, args: Vec<AuxValue>) -> Result<u32, String> {
        let id = self.next;
        self.next = self
            .next
            .checked_add(1)
            .ok_or("AX request counter exhausted")?;
        let m = Message::new(
            MessageHeader::new(0, 1, id, 0, 0, true),
            PayloadHeader::method_invocation(),
            Some(Aux::from_values(args)),
            Some(name.into()),
        );
        self.stream
            .write_all(&m.serialize())
            .await
            .map_err(|_| "AX write failed")?;
        self.stream.flush().await.map_err(|_| "AX flush failed")?;
        Ok(id)
    }
    async fn incoming(&mut self) -> Result<Incoming, String> {
        let mut payload = vec![];
        let mut index = 0u16;
        let mut identity = None;
        let header = loop {
            let mut h = [0u8; 32];
            self.stream
                .read_exact(&mut h)
                .await
                .map_err(|_| "AX connection closed")?;
            let part = u16::from_le_bytes([h[8], h[9]]);
            let count = u16::from_le_bytes([h[10], h[11]]);
            let len = u32_at(&h, 12)? as usize;
            let id = u32_at(&h, 16)?;
            let conv = u32_at(&h, 20)?;
            if u32_at(&h, 0)? != 0x1F3D5B79
                || u32_at(&h, 4)? != 32
                || count == 0
                || count > 256
                || part != index
                || len > MAX_BYTES
                || payload.len() + len > MAX_BYTES
                || identity.is_some_and(|v| v != (id, conv, count))
            {
                return Err("Invalid/bounded AX DTX frame".into());
            }
            identity = Some((id, conv, count));
            index += 1;
            // DTX fragment zero is a header-only envelope. Its length may
            // describe the whole message; no payload bytes follow this header.
            if count > 1 && part == 0 {
                continue;
            }
            let start = payload.len();
            payload.resize(start + len, 0);
            self.stream
                .read_exact(&mut payload[start..])
                .await
                .map_err(|_| "Short AX DTX payload")?;
            if part == count - 1 {
                break h;
            }
        };
        self.bytes += payload.len();
        if self.bytes > 40 * 1024 * 1024 {
            return Err("AX response byte budget".into());
        }
        if payload.len() < 16 {
            return Err("Short AX payload header".into());
        }
        let aux = u32_at(&payload, 4)? as usize;
        let total = u32_at(&payload, 8)? as usize;
        if aux > total || total.checked_add(16) != Some(payload.len()) {
            return Err("Invalid AX payload length".into());
        }
        if payload[0] == 4 {
            return Err("AX DTX error response".into());
        }
        let data = if total > aux {
            Some(archive::decode(&payload[16 + aux..])?)
        } else {
            None
        };
        let args = arguments(&payload[16..16 + aux])?;
        let id = u32_at(&header, 16)?;
        let conversation = u32_at(&header, 20)?;
        let needs_reply = u32_at(&header, 28)? == 1;
        if needs_reply {
            let version = data.as_ref().and_then(Value::as_string) == Some("hostAPIVersion");
            let reply = Message::new(
                MessageHeader::new(0, 1, id, conversation + 1, 0, false),
                PayloadHeader::default(),
                None,
                if version { Some(7u64.into()) } else { None },
            );
            let mut bytes = reply.serialize();
            if version {
                bytes[32] = 3;
            }
            self.stream
                .write_all(&bytes)
                .await
                .map_err(|_| "AX callback reply failed")?;
        }
        Ok(Incoming {
            id,
            conversation,
            needs_reply,
            data,
            args,
        })
    }
    async fn ack(&mut self, id: u32) -> Result<Option<Value>, String> {
        for _ in 0..256 {
            let m = self.incoming().await?;
            if m.id == id && m.conversation == 1 && !m.needs_reply {
                return Ok(m.data);
            }
        }
        Err("AX acknowledgement budget".into())
    }
    pub async fn read(
        &mut self,
        kind: u64,
        parameters: Value,
        token: Option<&Value>,
    ) -> Result<Value, String> {
        let body = archive::request(kind, parameters, token)?;
        let operation = async {
            self.invoke(
                "processDataFromHost:",
                vec![AuxValue::archived_value(Value::Data(body))],
            )
            .await?;
            for _ in 0..256 {
                let m = self.incoming().await?;
                if m.data.as_ref().and_then(Value::as_string)
                    != Some("processDataFromRemoteDevice:")
                {
                    continue;
                }
                let bytes = m
                    .args
                    .first()
                    .and_then(Value::as_data)
                    .ok_or("AX callback missing data")?;
                let reply = archive::decode(bytes)?;
                let d = reply.as_dictionary().ok_or("AX reply dictionary")?;
                if d.get("associatedRequestType")
                    .and_then(Value::as_unsigned_integer)
                    != Some(kind)
                {
                    continue;
                }
                if d.get("error").is_some_and(|v| {
                    v.as_unsigned_integer() != Some(0) && !v.as_uid().is_some_and(|u| u.get() == 0)
                }) {
                    return Err(format!(
                        "AX request type {kind} refused: {}",
                        d.get("error")
                            .and_then(Value::as_unsigned_integer)
                            .map(|n| n.to_string())
                            .unwrap_or_else(|| "unknown error".into())
                    ));
                }
                return d
                    .get("resultData")
                    .cloned()
                    .ok_or_else(|| "AX result missing".into());
            }
            Err("AX callback budget".into())
        };
        tokio::time::timeout(Duration::from_secs(4), operation)
            .await
            .map_err(|_| "AX semantic request timed out; session must close".to_string())?
    }
    pub async fn hit(&mut self, x: f64, y: f64) -> Result<Value, String> {
        self.read(6, format!("{{{x}, {y}}}").into(), None).await
    }
    async fn attributes(&mut self, token: &Value, ids: &[u64]) -> Result<Value, String> {
        self.read(
            5,
            fields(&[(
                "attributes",
                Value::Array(ids.iter().map(|n| (*n).into()).collect()),
            )]),
            Some(token),
        )
        .await
    }
    pub async fn graph(&mut self, x: f64, y: f64) -> Result<(u64, Vec<Value>), String> {
        self.bytes = 0;
        let selected = self.hit(x, y).await?;
        let (pid, _) = identity(&selected)?;
        let root = self.read(1, fields(&[("pid", pid.into())]), None).await?;
        if identity(&root)?.0 != pid
            || root
                .as_dictionary()
                .and_then(|d| d.get("isApplicationElement"))
                .and_then(Value::as_boolean)
                != Some(true)
        {
            return Err("AX application mismatch".into());
        }
        let mut pending = VecDeque::from([(root.clone(), 0)]);
        let mut seen = HashSet::new();
        let mut nodes = vec![];
        while let Some((token, depth)) = pending.pop_front() {
            let key = identity(&token)?;
            if key.0 != pid || !seen.insert(key) || depth > 32 || nodes.len() >= 512 {
                return Err("AX graph identity/size/depth limit".into());
            }
            let mut attrs = self
                .attributes(
                    &token,
                    &[8, 21, 25, 27, 28, 30, 32, 33, 42, 45, 46, 51, 53, 77],
                )
                .await?;
            let d = attrs.as_dictionary_mut().ok_or("AX attributes missing")?;
            if !d
                .get("33")
                .and_then(Value::as_string)
                .is_some_and(|s| !s.trim().is_empty())
            {
                let label = self.attributes(&token, &[3]).await?;
                if let Some(v) = label.as_dictionary().and_then(|d| d.get("3")) {
                    d.insert("3".into(), v.clone());
                }
            }
            let children = d
                .get("8")
                .and_then(Value::as_array)
                .ok_or("AX children missing; no partial graph")?;
            pending.extend(children.iter().cloned().map(|t| (t, depth + 1)));
            d.insert("token".into(), token);
            nodes.push(attrs);
        }
        let fresh = self.attributes(&root, &[8, 21]).await?;
        let first = nodes
            .first()
            .and_then(Value::as_dictionary)
            .ok_or("Empty AX graph")?;
        let last = fresh.as_dictionary().ok_or("AX root missing")?;
        if first.get("8") != last.get("8")
            || first.get("21") != last.get("21")
            || identity(&self.hit(x, y).await?)?.0 != pid
        {
            return Err("AX foreground or root changed".into());
        }
        Ok((pid, nodes))
    }
    pub async fn close(&mut self) -> Result<(), String> {
        if !self.subscribed {
            return Ok(());
        }
        self.subscribed = false;
        let id = self
            .invoke(
                "clientNeedsAccessibility:",
                vec![AuxValue::archived_value(false)],
            )
            .await?;
        self.ack(id).await?;
        Ok(())
    }
}
pub fn identity(v: &Value) -> Result<(u64, u64), String> {
    let d = v.as_dictionary().ok_or("AX token missing")?;
    let pid = d
        .get("pid")
        .and_then(Value::as_unsigned_integer)
        .filter(|p| *p > 0)
        .ok_or("Invalid AX PID")?;
    let object = d
        .get("objectID")
        .and_then(Value::as_unsigned_integer)
        .ok_or("Invalid AX object ID")?;
    Ok((pid, object))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_truncated_aux_before_allocation() {
        let mut bytes = vec![0; 16];
        bytes.extend_from_slice(&2u32.to_le_bytes());
        bytes.extend_from_slice(&u32::MAX.to_le_bytes());
        assert!(arguments(&bytes).is_err());
        assert!(arguments(&[0; 3]).is_err());
    }
    #[test]
    fn primitive_arguments_preserve_callback_positions() {
        let bytes = Aux::from_values(vec![
            AuxValue::I64(-12),
            AuxValue::Double(1.5),
            AuxValue::String("next".into()),
        ])
        .serialize();
        let values = arguments(&bytes).unwrap();
        assert_eq!(values.len(), 3);
        assert_eq!(values[0].as_signed_integer(), Some(-12));
        assert_eq!(values[1].as_real(), Some(1.5));
        assert_eq!(values[2].as_string(), Some("next"));
    }
    #[tokio::test]
    async fn failed_subscription_attempts_unsubscribe_before_drop() {
        let (mut server, reader) = tokio::io::duplex(4096);
        let peer = tokio::spawn(async move {
            async fn request(server: &mut tokio::io::DuplexStream) -> (u32, Value) {
                let mut h = [0u8; 32];
                server.read_exact(&mut h).await.unwrap();
                let mut p = vec![0; u32_at(&h, 12).unwrap() as usize];
                server.read_exact(&mut p).await.unwrap();
                let aux = u32_at(&p, 4).unwrap() as usize;
                (
                    u32_at(&h, 16).unwrap(),
                    archive::decode(&p[16 + aux..]).unwrap(),
                )
            }
            let (id, name) = request(&mut server).await;
            assert_eq!(name.as_string(), Some("deviceAPIVersion"));
            let reply = Message::new(
                MessageHeader::new(0, 1, id, 1, 0, false),
                PayloadHeader::default(),
                None,
                Some(26u64.into()),
            )
            .serialize();
            server.write_all(&reply).await.unwrap();
            let (id, name) = request(&mut server).await;
            assert_eq!(name.as_string(), Some("clientNeedsAccessibility:"));
            // A protocol error after the subscribe write must still trigger close.
            let mut reply = Message::new(
                MessageHeader::new(0, 1, id, 1, 0, false),
                PayloadHeader::default(),
                None,
                None,
            )
            .serialize();
            reply[32] = 4;
            server.write_all(&reply).await.unwrap();
            let (id, name) = request(&mut server).await;
            assert_eq!(name.as_string(), Some("clientNeedsAccessibility:"));
            let reply = Message::new(
                MessageHeader::new(0, 1, id, 1, 0, false),
                PayloadHeader::default(),
                None,
                None,
            )
            .serialize();
            server.write_all(&reply).await.unwrap();
        });
        assert!(Ax::new(Box::new(reader)).await.is_err());
        peer.await.unwrap();
    }
    #[tokio::test]
    async fn fragment_zero_length_is_metadata_not_payload() {
        let message = Message::new(
            MessageHeader::new(0, 1, 42, 1, 0, false),
            PayloadHeader::default(),
            None,
            Some(26u64.into()),
        )
        .serialize();
        let payload = &message[32..];
        let mut first = MessageHeader::new(0, 2, 42, 1, 0, false).serialize();
        first[12..16].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        let mut last = MessageHeader::new(1, 2, 42, 1, 0, false).serialize();
        last[12..16].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        let mut bytes = first;
        bytes.extend(last);
        bytes.extend_from_slice(payload);
        let (mut writer, reader) = tokio::io::duplex(4096);
        tokio::spawn(async move {
            writer.write_all(&bytes).await.unwrap();
        });
        let mut ax = Ax {
            stream: Box::new(reader),
            next: 1,
            bytes: 0,
            subscribed: false,
        };
        let received = ax.incoming().await.unwrap();
        assert_eq!(received.id, 42);
        assert_eq!(received.data.unwrap().as_unsigned_integer(), Some(26));
    }
}
