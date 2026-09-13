use std::sync::Arc;

use anyhow::{Context, Result, bail};
use matrix_sdk::{Room, ruma::events::room::message::RoomMessageEventContent};
use serde::{Deserialize, Serialize};

use crate::now_secs;

const ADMIN_API: &str = "http://127.0.0.1:8008/_synapse/admin/v1/registration_tokens/new";
const INVITE_BASE: &str = "https://cinny.matrix.odarah.org/register/matrix.odarah.org/?token=";
const TOKEN_TTL_SECS: u64 = 24 * 60 * 60;

#[derive(Serialize)]
struct CreateTokenRequest {
    uses_allowed: u8,
    expiry_time: u64,
    length: u8,
}

#[derive(Deserialize)]
struct CreateTokenResponse {
    token: String,
}

pub(crate) async fn create_registration_token(
    room: &Room,
    http: &reqwest::Client,
    access_token: &Arc<str>,
) -> Result<()> {
    let requested_expiry_ms = now_secs()?
        .checked_add(TOKEN_TTL_SECS)
        .and_then(|seconds| seconds.checked_mul(1000))
        .context("expiry overflow")?;
    let response = http
        .post(ADMIN_API)
        .bearer_auth(access_token.as_ref())
        .json(&CreateTokenRequest {
            uses_allowed: 1,
            expiry_time: requested_expiry_ms,
            length: 32,
        })
        .send()
        .await
        .context("call private registration-token API")?
        .error_for_status()
        .context("registration-token API rejected request")?
        .json::<CreateTokenResponse>()
        .await
        .context("decode registration-token response")?;
    if response.token.is_empty() {
        bail!("registration-token response omitted token");
    }

    let encoded: String = url::form_urlencoded::byte_serialize(response.token.as_bytes()).collect();
    let requested_expiry_ms = i64::try_from(requested_expiry_ms)
        .context("registration-token expiry exceeds supported range")?;
    let expiry = chrono::DateTime::from_timestamp_millis(requested_expiry_ms)
        .context("invalid registration-token expiry")?;
    room.send(RoomMessageEventContent::text_plain(format!(
        "{INVITE_BASE}{encoded}\nExpires {}.",
        expiry.to_rfc3339()
    )))
    .await?;
    Ok(())
}
