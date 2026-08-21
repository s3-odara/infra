use std::{
    env,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use matrix_sdk::{
    Client, Room, RoomMemberships, SessionMeta,
    authentication::{SessionTokens, matrix::MatrixSession},
    config::SyncSettings,
    deserialized_responses::EncryptionInfo,
    ruma::{
        OwnedDeviceId, OwnedUserId,
        events::room::{
            member::{MembershipState, StrippedRoomMemberEvent},
            message::{MessageType, RoomMessageEventContent, SyncRoomMessageEvent},
        },
    },
    store::StateStoreDataKey,
};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

const HOMESERVER: &str = "http://127.0.0.1:8008";
const ADMIN_API: &str = "http://127.0.0.1:8008/_synapse/admin/v1/registration_tokens/new";
const INVITER: &str = "@odara:matrix.odarah.org";
const BOT_USER: &str = "@invite-bot:matrix.odarah.org";
const INVITE_BASE: &str = "https://cinny.matrix.odarah.org/register/matrix.odarah.org/?token=";
const TOKEN_TTL_SECS: u64 = 60 * 60;
const COOLDOWN_SECS: u64 = 10 * 60;

#[derive(Clone)]
struct App {
    http: reqwest::Client,
    access_token: Arc<str>,
    state_path: PathBuf,
    state: Arc<Mutex<PersistentState>>,
}

#[derive(Default, Deserialize, Serialize)]
struct PersistentState {
    last_issued_at: Option<u64>,
}

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

fn now_secs() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?
        .as_secs())
}

fn load_state(path: &Path) -> Result<PersistentState> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).context("parse invite-bot state"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(PersistentState::default())
        }
        Err(error) => Err(error).context("read invite-bot state"),
    }
}

fn save_state(path: &Path, state: &PersistentState) -> Result<()> {
    let temporary = path.with_extension("json.new");
    std::fs::write(&temporary, serde_json::to_vec(state)?)?;
    std::fs::rename(temporary, path)?;
    Ok(())
}

async fn is_expected_dm(room: &Room) -> Result<bool> {
    let members = room.members(RoomMemberships::ACTIVE).await?;
    Ok(members.len() == 2
        && members
            .iter()
            .any(|member| member.user_id().as_str() == INVITER)
        && members
            .iter()
            .any(|member| member.user_id() == room.own_user_id()))
}

async fn handle_invite(event: StrippedRoomMemberEvent, room: Room) {
    if event.sender.as_str() != INVITER
        || event.state_key != room.own_user_id()
        || event.content.membership != MembershipState::Invite
    {
        return;
    }

    match is_expected_dm(&room).await {
        Ok(true) => {
            if let Err(error) = room.join().await {
                eprintln!("failed to join authorized DM invitation: {error}");
            }
        }
        Ok(false) => eprintln!("ignored authorized invitation with unexpected active members"),
        Err(error) => eprintln!("failed to validate authorized invitation membership: {error}"),
    }
}

async fn handle_message(
    event: SyncRoomMessageEvent,
    room: Room,
    encryption_info: Option<EncryptionInfo>,
    app: App,
) {
    if let Err(error) = try_handle_message(event, room, encryption_info, app).await {
        eprintln!("invite request failed: {error:#}");
    }
}

async fn try_handle_message(
    event: SyncRoomMessageEvent,
    room: Room,
    encryption_info: Option<EncryptionInfo>,
    app: App,
) -> Result<()> {
    let original = match event.as_original() {
        Some(original) => original,
        None => return Ok(()),
    };

    if original.sender.as_str() != INVITER || encryption_info.is_none() {
        return Ok(());
    }
    if !is_expected_dm(&room).await? {
        return Ok(());
    }
    let MessageType::Text(text) = &original.content.msgtype else {
        return Ok(());
    };
    if text.body != "invite" {
        return Ok(());
    }

    let now = now_secs()?;
    {
        let mut state = app.state.lock().await;
        if state
            .last_issued_at
            .is_some_and(|last| now.saturating_sub(last) < COOLDOWN_SECS)
        {
            save_state(&app.state_path, &state)?;
            room.send(RoomMessageEventContent::text_plain(
                "An invite was issued recently; try again later.",
            ))
            .await?;
            return Ok(());
        }
        state.last_issued_at = Some(now);
        save_state(&app.state_path, &state)?;
    }

    let requested_expiry_ms = now
        .checked_add(TOKEN_TTL_SECS)
        .and_then(|seconds| seconds.checked_mul(1000))
        .context("expiry overflow")?;
    let response = app
        .http
        .post(ADMIN_API)
        .bearer_auth(app.access_token.as_ref())
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
    let expiry = chrono::DateTime::from_timestamp_millis(requested_expiry_ms as i64)
        .context("invalid registration-token expiry")?;
    let reply = format!("{INVITE_BASE}{encoded}\nExpires {}.", expiry.to_rfc3339());
    room.send(RoomMessageEventContent::text_plain(reply))
        .await?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let access_token: Arc<str> = env::var("MATRIX_ACCESS_TOKEN")
        .context("MATRIX_ACCESS_TOKEN is not set")?
        .into();
    let device_id: OwnedDeviceId = env::var("MATRIX_DEVICE_ID")
        .context("MATRIX_DEVICE_ID is not set")?
        .into();
    let user_id: OwnedUserId = env::var("MATRIX_USER_ID")
        .context("MATRIX_USER_ID is not set")?
        .parse()
        .context("invalid MATRIX_USER_ID")?;
    if user_id.as_str() != BOT_USER {
        bail!("MATRIX_USER_ID must be {BOT_USER}");
    }

    let state_dir = PathBuf::from(
        env::var("STATE_DIRECTORY").unwrap_or_else(|_| "/var/lib/matrix-invite-bot".to_owned()),
    );
    let state_path = state_dir.join("cooldown.json");
    let client = Client::builder()
        .homeserver_url(HOMESERVER)
        .sqlite_store(state_dir.join("matrix-sdk"), None)
        .build()
        .await?;
    client
        .restore_session(MatrixSession {
            meta: SessionMeta {
                user_id: user_id.clone(),
                device_id: device_id.clone(),
            },
            tokens: SessionTokens {
                access_token: access_token.to_string(),
                refresh_token: None,
            },
        })
        .await?;
    let whoami = client
        .whoami()
        .await
        .context("verify restored Matrix session")?;
    if whoami.user_id != user_id || whoami.device_id.as_ref() != Some(&device_id) || whoami.is_guest
    {
        bail!("restored Matrix session is not the configured dedicated bot device");
    }

    let app = App {
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .build()?,
        access_token,
        state_path: state_path.clone(),
        state: Arc::new(Mutex::new(load_state(&state_path)?)),
    };
    // Join room invitations only when they come from the sole authorized MXID.
    client.add_event_handler(handle_invite);

    // Only a truly new store gets a handler-free baseline. On restart the
    // message handler is present before catch-up from the persisted token.
    let has_sync_token = client
        .state_store()
        .get_kv_data(StateStoreDataKey::SyncToken)
        .await?
        .is_some();
    if !has_sync_token {
        client.sync_once(SyncSettings::default()).await?;
    }
    client.add_event_handler(move |event, room, encryption_info| {
        handle_message(event, room, encryption_info, app.clone())
    });

    client.sync(SyncSettings::default()).await?;
    Ok(())
}
