use std::{collections::BTreeSet, sync::Arc, time::Duration};

use anyhow::{Context, Result};
use matrix_sdk::{
    Client,
    deserialized_responses::{
        ProcessedToDeviceEvent, TimelineEventKind, ToDeviceUnableToDecryptReason,
        UnableToDecryptReason,
    },
    ruma::OwnedUserId,
    sync::SyncResponse,
};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::{BOT_USER, HOMESERVER, INVITER, logging};

#[derive(Clone)]
pub(crate) struct Diagnostics {
    client: Client,
    http: reqwest::Client,
    access_token: Arc<str>,
    inviter: OwnedUserId,
    previous_devices: Arc<Mutex<Option<DeviceSnapshot>>>,
}

#[derive(Clone, PartialEq, Eq)]
struct DeviceSnapshot {
    ids: BTreeSet<String>,
    verified: usize,
}

impl Diagnostics {
    pub(crate) fn new(
        client: Client,
        http: reqwest::Client,
        access_token: Arc<str>,
    ) -> Result<Self> {
        Ok(Self {
            client,
            http,
            access_token,
            inviter: INVITER.parse().context("invalid configured inviter")?,
            previous_devices: Arc::new(Mutex::new(None)),
        })
    }

    pub(crate) async fn observe(&self, response: &SyncResponse) {
        for line in sync_diagnostics(response) {
            eprintln!("{line}");
        }

        // get_user_devices only reads the SDK crypto-store snapshot here. Do
        // not force a key query, verify a device, or change key-sharing policy.
        let devices = match self
            .client
            .encryption()
            .get_user_devices(&self.inviter)
            .await
        {
            Ok(devices) => devices,
            Err(error) => {
                logging::error("device_cache_read_failed", &error);
                return;
            }
        };
        let mut snapshot = DeviceSnapshot {
            ids: BTreeSet::new(),
            verified: 0,
        };
        for device in devices.devices() {
            snapshot.ids.insert(device.device_id().to_string());
            snapshot.verified += usize::from(device.is_verified());
        }
        let mut previous = self.previous_devices.lock().await;
        let first_snapshot = previous.is_none();
        if previous.as_ref() != Some(&snapshot) {
            eprintln!(
                "bot event=device_cache_snapshot devices={} verified_devices={} changed={}",
                snapshot.ids.len(),
                snapshot.verified,
                previous.is_some(),
            );
            *previous = Some(snapshot.clone());
        }
        drop(previous);
        if first_snapshot {
            // Once per start, after SDK sync and key uploads have run. Bound
            // these observational requests so diagnostics cannot stall sync.
            let probes = async {
                if let Err(error) = self.compare_server_keys(&snapshot).await {
                    logging::error("server_keys_probe_failed", &error);
                }
                if let Err(error) = self.read_one_time_key_count().await {
                    logging::error("one_time_key_count_probe_failed", &error);
                }
            };
            if tokio::time::timeout(Duration::from_secs(3), probes)
                .await
                .is_err()
            {
                eprintln!("bot event=crypto_probe_timeout");
            }
        }
    }

    async fn compare_server_keys(&self, cached: &DeviceSnapshot) -> Result<()> {
        let device_id = self
            .client
            .device_id()
            .context("bot device ID is unavailable")?;
        // Read server public keys directly without updating the SDK's cache or trust.
        let response = self
            .http
            .post(format!("{HOMESERVER}/_matrix/client/v3/keys/query"))
            .bearer_auth(self.access_token.as_ref())
            .json(&json!({"device_keys": {BOT_USER: [], INVITER: []}}))
            .send()
            .await?
            .error_for_status()?
            .json::<Value>()
            .await?;
        let local_ed25519 = self.client.encryption().ed25519_key().await;
        let local_curve25519 = self
            .client
            .encryption()
            .curve25519_key()
            .await
            .map(|key| key.to_base64());
        let line = server_key_report(
            &response,
            cached,
            device_id.as_str(),
            (local_ed25519.as_deref(), local_curve25519.as_deref()),
        )
        .context("invalid server device-key response")?;
        eprintln!("{line}");
        Ok(())
    }

    async fn read_one_time_key_count(&self) -> Result<()> {
        // The empty upload request only reads counts: no device, one-time, or
        // fallback keys are supplied. Never use /keys/claim for diagnostics;
        // claiming would consume one-time keys.
        let response = self
            .http
            .post(format!("{HOMESERVER}/_matrix/client/v3/keys/upload"))
            .bearer_auth(self.access_token.as_ref())
            .json(&json!({}))
            .send()
            .await?
            .error_for_status()?
            .json::<Value>()
            .await?;
        let count = one_time_key_count(&response).context("invalid one-time-key count response")?;
        eprintln!("bot event=one_time_key_count signed_curve25519={count}");
        Ok(())
    }
}

fn server_key_report(
    response: &Value,
    cached: &DeviceSnapshot,
    device_id: &str,
    local_keys: (Option<&str>, Option<&str>),
) -> Option<String> {
    let device_keys = response.get("device_keys")?.as_object()?;
    let empty = serde_json::Map::new();
    let bot_devices = match device_keys.get(BOT_USER) {
        Some(devices) => devices.as_object()?,
        None => &empty,
    };
    let inviter_devices = match device_keys.get(INVITER) {
        Some(devices) => devices.as_object()?,
        None => &empty,
    };
    let own_keys = bot_devices
        .get(device_id)
        .and_then(|device| device.get("keys"));
    let server_ed25519 = own_keys
        .and_then(|keys| keys.get(format!("ed25519:{device_id}")))
        .and_then(Value::as_str);
    let server_curve25519 = own_keys
        .and_then(|keys| keys.get(format!("curve25519:{device_id}")))
        .and_then(Value::as_str);
    let missing = inviter_devices
        .keys()
        .filter(|id| !cached.ids.contains(*id))
        .count();
    let stale = cached
        .ids
        .iter()
        .filter(|id| !inviter_devices.contains_key(*id))
        .count();
    Some(format!(
        "bot event=server_keys_snapshot bot_devices={} server_devices={} cached_devices={} missing_cached={} stale_cached={} ed25519={} curve25519={}",
        bot_devices.len(),
        inviter_devices.len(),
        cached.ids.len(),
        missing,
        stale,
        key_match(local_keys.0, server_ed25519),
        key_match(local_keys.1, server_curve25519),
    ))
}

fn key_match(local: Option<&str>, server: Option<&str>) -> &'static str {
    match (local, server) {
        (None, _) => "missing_local",
        (_, None) => "missing_server",
        (Some(local), Some(server)) if local == server => "match",
        _ => "mismatch",
    }
}

fn one_time_key_count(response: &Value) -> Option<u64> {
    let counts = response.get("one_time_key_counts")?.as_object()?;
    match counts.get("signed_curve25519") {
        Some(count) => count.as_u64(),
        None => Some(0),
    }
}

fn sync_diagnostics(response: &SyncResponse) -> Vec<String> {
    let mut lines = Vec::new();
    for room in response.rooms.joined.values() {
        for event in &room.timeline.events {
            if event.sender().as_deref().map(|id| id.as_str()) != Some(INVITER) {
                continue;
            }
            if let TimelineEventKind::UnableToDecrypt { utd_info, .. } = &event.kind {
                let (reason, withheld) = room_failure(&utd_info.reason);
                lines.push(format!(
                    "bot event=room_event_undecryptable reason={reason} withheld={withheld}"
                ));
            }
        }
    }
    for event in &response.to_device {
        let raw = event.as_raw();
        if raw
            .get_field::<OwnedUserId>("sender")
            .ok()
            .flatten()
            .as_deref()
            .map(|id| id.as_str())
            != Some(INVITER)
        {
            continue;
        }
        match event {
            ProcessedToDeviceEvent::UnableToDecrypt { utd_info, .. } => {
                let reason = match utd_info.reason {
                    ToDeviceUnableToDecryptReason::DecryptionFailure => "decryption_failure",
                    ToDeviceUnableToDecryptReason::UnverifiedSenderDevice => {
                        "unverified_sender_device"
                    }
                    ToDeviceUnableToDecryptReason::NoOlmMachine => "no_olm_machine",
                    ToDeviceUnableToDecryptReason::EncryptionIsDisabled => "encryption_disabled",
                };
                lines.push(format!("bot event=to_device_undecryptable reason={reason}"));
            }
            ProcessedToDeviceEvent::Invalid(_) => {
                lines.push("bot event=to_device_invalid".to_owned());
            }
            ProcessedToDeviceEvent::Decrypted { .. } | ProcessedToDeviceEvent::PlainText(_) => {
                let event_type = raw.get_field::<String>("type").ok().flatten();
                match event_type.as_deref() {
                    Some("m.room_key.withheld" | "org.matrix.room_key.withheld") => {
                        #[derive(Deserialize)]
                        struct Content {
                            code: String,
                        }
                        let code = raw.get_field::<Content>("content").ok().flatten();
                        let code =
                            withheld_code(code.as_ref().map(|content| content.code.as_str()));
                        // The free-form reason and all key/session data are deliberately omitted.
                        lines.push(format!("bot event=room_key_withheld code={code}"));
                    }
                    Some("m.room_key" | "m.forwarded_room_key") => {
                        let decrypted = matches!(event, ProcessedToDeviceEvent::Decrypted { .. });
                        lines.push(format!("bot event=room_key_received encrypted={decrypted}"));
                    }
                    _ => {}
                }
            }
        }
    }
    lines
}

fn room_failure(reason: &UnableToDecryptReason) -> (&'static str, &'static str) {
    match reason {
        UnableToDecryptReason::MalformedEncryptedEvent => ("malformed_event", "none"),
        UnableToDecryptReason::MissingMegolmSession {
            withheld_code: code,
        } => (
            "missing_room_key",
            withheld_code(code.as_ref().map(|code| code.as_str())),
        ),
        UnableToDecryptReason::UnknownMegolmMessageIndex => ("unknown_message_index", "none"),
        UnableToDecryptReason::MegolmDecryptionFailure => ("megolm_decryption_failure", "none"),
        UnableToDecryptReason::PayloadDeserializationFailure => {
            ("invalid_decrypted_payload", "none")
        }
        UnableToDecryptReason::MismatchedIdentityKeys => ("identity_key_mismatch", "none"),
        UnableToDecryptReason::SenderIdentityNotTrusted(_) => {
            ("sender_identity_not_trusted", "none")
        }
        _ => ("unknown", "none"),
    }
}

fn withheld_code(code: Option<&str>) -> &'static str {
    match code {
        None => "none",
        Some("m.blacklisted") => "m.blacklisted",
        Some("m.unverified") => "m.unverified",
        Some("m.unauthorised" | "m.unauthorized") => "m.unauthorised",
        Some("m.unavailable") => "m.unavailable",
        Some("m.no_olm") => "m.no_olm",
        Some("m.history_not_shared") => "m.history_not_shared",
        Some(_) => "other",
    }
}

#[cfg(test)]
mod tests {
    use matrix_sdk::{
        deserialized_responses::{ToDeviceUnableToDecryptInfo, WithheldCode},
        ruma::serde::Raw,
    };
    use serde_json::json;

    use super::*;

    #[test]
    fn to_device_failure_and_withheld_logs_exclude_event_payloads() {
        let secret = "PRIVATE_MESSAGE_KEY_TOKEN";
        let raw = Raw::new(&json!({
            "sender": INVITER,
            "type": "m.room_key.withheld",
            "content": {"code": "m.no_olm", "reason": secret, "session_key": secret},
        }))
        .unwrap();
        let mut response = SyncResponse::default();
        response.to_device.push(ProcessedToDeviceEvent::PlainText(
            raw.clone().cast_unchecked(),
        ));
        response
            .to_device
            .push(ProcessedToDeviceEvent::UnableToDecrypt {
                encrypted_event: raw.cast_unchecked(),
                utd_info: ToDeviceUnableToDecryptInfo {
                    reason: ToDeviceUnableToDecryptReason::DecryptionFailure,
                },
            });
        let lines = sync_diagnostics(&response);
        assert_eq!(
            lines,
            [
                "bot event=room_key_withheld code=m.no_olm",
                "bot event=to_device_undecryptable reason=decryption_failure",
            ]
        );
        assert!(!lines.join("\n").contains(secret));
    }

    #[test]
    fn timeline_failures_report_reasons_without_room_ids_or_content() {
        use matrix_sdk::deserialized_responses::{TimelineEvent, UnableToDecryptInfo};

        let raw = Raw::new(&json!({
            "sender": INVITER,
            "type": "m.room.encrypted",
            "event_id": "$private-event:example.org",
            "origin_server_ts": 1,
            "content": {"ciphertext": "PRIVATE_MESSAGE_KEY_TOKEN"},
        }))
        .unwrap();
        let event = TimelineEvent::from_utd(
            raw.cast_unchecked(),
            UnableToDecryptInfo {
                session_id: Some("PRIVATE_SESSION_ID".to_owned()),
                reason: UnableToDecryptReason::MismatchedIdentityKeys,
            },
        );
        let mut response = SyncResponse::default();
        response
            .rooms
            .joined
            .entry("!private-room:example.org".parse().unwrap())
            .or_default()
            .timeline
            .events
            .push(event);
        assert_eq!(
            sync_diagnostics(&response),
            ["bot event=room_event_undecryptable reason=identity_key_mismatch withheld=none",]
        );
    }

    #[test]
    fn unknown_withheld_codes_cannot_inject_arbitrary_log_text() {
        assert_eq!(
            withheld_code(Some("PRIVATE_MESSAGE_KEY_TOKEN\ninjected")),
            "other"
        );
    }

    #[test]
    fn room_failure_distinguishes_missing_keys_from_trust_failures() {
        let reason = UnableToDecryptReason::MissingMegolmSession {
            withheld_code: Some(WithheldCode::NoOlm),
        };
        assert_eq!(room_failure(&reason), ("missing_room_key", "m.no_olm"));
        let reason = UnableToDecryptReason::SenderIdentityNotTrusted(
            matrix_sdk::deserialized_responses::VerificationLevel::UnsignedDevice,
        );
        assert_eq!(
            room_failure(&reason),
            ("sender_identity_not_trusted", "none")
        );
    }

    #[test]
    fn server_key_report_only_emits_counts_and_match_statuses() {
        let response = json!({"device_keys": {
            BOT_USER: {"BOT_DEVICE": {"keys": {
                "ed25519:BOT_DEVICE": "PRIVATE_ED25519_VALUE",
                "curve25519:BOT_DEVICE": "PRIVATE_CURVE25519_VALUE",
            }}},
            INVITER: {"KNOWN_DEVICE": {}, "NEW_DEVICE": {}},
        }});
        let cached = DeviceSnapshot {
            ids: BTreeSet::from(["KNOWN_DEVICE".to_owned(), "STALE_DEVICE".to_owned()]),
            verified: 0,
        };
        assert_eq!(
            server_key_report(
                &response,
                &cached,
                "BOT_DEVICE",
                (Some("PRIVATE_ED25519_VALUE"), Some("DIFFERENT_KEY")),
            )
            .unwrap(),
            "bot event=server_keys_snapshot bot_devices=1 server_devices=2 cached_devices=2 missing_cached=1 stale_cached=1 ed25519=match curve25519=mismatch"
        );
        let absent = json!({"device_keys": {}});
        let report =
            server_key_report(&absent, &cached, "BOT_DEVICE", (Some("KEY"), Some("KEY"))).unwrap();
        assert!(report.contains("bot_devices=0"));
        assert!(report.contains("ed25519=missing_server curve25519=missing_server"));
        assert_eq!(key_match(None, Some("KEY")), "missing_local");
    }

    #[test]
    fn one_time_key_counts_accept_zero_but_reject_malformed_values() {
        assert_eq!(
            one_time_key_count(&json!({"one_time_key_counts": {"signed_curve25519": 50}})),
            Some(50)
        );
        assert_eq!(
            one_time_key_count(&json!({"one_time_key_counts": {}})),
            Some(0)
        );
        assert_eq!(
            one_time_key_count(&json!({"one_time_key_counts": {"signed_curve25519": "TOKEN"}})),
            None
        );
        assert_eq!(one_time_key_count(&json!({})), None);
    }

    #[test]
    fn cache_changes_detect_device_replacement_even_with_the_same_count() {
        let first = DeviceSnapshot {
            ids: BTreeSet::from(["OLD".to_owned()]),
            verified: 0,
        };
        let second = DeviceSnapshot {
            ids: BTreeSet::from(["NEW".to_owned()]),
            verified: 0,
        };
        assert!(first != second);
        assert_eq!(first.ids.len(), second.ids.len());
    }
}
