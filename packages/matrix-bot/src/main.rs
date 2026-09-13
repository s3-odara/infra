mod call;
mod invite;

use std::{
    env,
    path::PathBuf,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use call::CallService;
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

const HOMESERVER: &str = "http://127.0.0.1:8008";
pub(crate) const INVITER: &str = "@odara:matrix.odarah.org";
pub(crate) const BOT_USER: &str = "@invite-bot:matrix.odarah.org";

#[derive(Clone)]
struct App {
    http: reqwest::Client,
    access_token: Arc<str>,
    calls: CallService,
}

pub(crate) fn now_secs() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?
        .as_secs())
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
        eprintln!("message handling failed: {error:#}");
    }
}

async fn try_handle_message(
    event: SyncRoomMessageEvent,
    room: Room,
    encryption_info: Option<EncryptionInfo>,
    app: App,
) -> Result<()> {
    let Some(original) = event.as_original() else {
        return Ok(());
    };
    if original.sender.as_str() != INVITER
        || encryption_info.is_none()
        || !is_expected_dm(&room).await?
    {
        return Ok(());
    }
    let MessageType::Text(text) = &original.content.msgtype else {
        return Ok(());
    };

    let recognized = text.body == "invite"
        || text.body.starts_with("call create ")
        || text.body.starts_with("call close ");
    if !recognized {
        return Ok(());
    }

    let result: Result<()> = async {
        if text.body == "invite" {
            invite::create_registration_token(&room, &app.http, &app.access_token).await?;
        } else if let Some(name) = call::parse_call_name(&text.body)? {
            app.calls.create(&room, name).await?;
        } else if let Some(room_id) = call::parse_close_room(&text.body)? {
            if !app.calls.is_managed(room_id.as_str()).await {
                bail!("このroomはbotの管理対象ではありません");
            }
            app.calls.close(&room_id).await?;
        }
        Ok(())
    }
    .await;

    if let Err(error) = result {
        eprintln!("bot request failed: {error:#}");
        room.send(RoomMessageEventContent::text_plain(
            "処理に失敗しました。詳細はbotのjournalを確認してください。",
        ))
        .await
        .context("notify command failure")?;
    }
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
        env::var("STATE_DIRECTORY").unwrap_or_else(|_| "/var/lib/matrix-bot".to_owned()),
    );
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

    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()?;
    let guest_credentials = match (
        env::var("GUEST_ADMIN_ACCESS_TOKEN"),
        env::var("GUEST_SENTINEL_TOKEN"),
    ) {
        (Ok(token), Ok(sentinel)) if !token.is_empty() && !sentinel.is_empty() => {
            Some((token, sentinel))
        }
        _ => {
            eprintln!(
                "guest registration gating is disabled: set GUEST_ADMIN_ACCESS_TOKEN and \
                 GUEST_SENTINEL_TOKEN to enable it"
            );
            None
        }
    };
    let calls = CallService::load(
        client.clone(),
        http.clone(),
        access_token.clone(),
        state_dir.join("managed-calls.json"),
        guest_credentials,
    )?;
    let app = App {
        http,
        access_token,
        calls,
    };

    // Reconcile only closes the gate, so restore it here for persisted calls.
    if let Err(error) = app.calls.restore_guest_registration().await {
        eprintln!("failed to reconcile guest registration on startup: {error:#}");
    }
    client.add_event_handler(handle_invite);

    let has_sync_token = client
        .state_store()
        .get_kv_data(StateStoreDataKey::SyncToken)
        .await?
        .is_some();
    if !has_sync_token {
        client.sync_once(SyncSettings::default()).await?;
    }
    let message_app = app.clone();
    client.add_event_handler(move |event, room, encryption_info| {
        handle_message(event, room, encryption_info, message_app.clone())
    });

    tokio::spawn(app.calls.reconcile_loop());
    client.sync(SyncSettings::default()).await?;
    Ok(())
}
