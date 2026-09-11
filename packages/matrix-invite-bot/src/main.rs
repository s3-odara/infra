use std::{
    collections::BTreeMap,
    env, fs,
    path::PathBuf,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use matrix_sdk::{
    Client, Room, RoomMemberships, RoomState, SessionMeta,
    authentication::{SessionTokens, matrix::MatrixSession},
    config::SyncSettings,
    deserialized_responses::EncryptionInfo,
    ruma::{
        api::client::{
            room::{
                Visibility,
                create_room::{RoomPowerLevelsContentOverride, v3::Request as CreateRoomRequest},
            },
        },
        events::{
            AnyInitialStateEvent,
            room::{
                join_rules::RoomJoinRulesEventContent,
                member::{MembershipState, StrippedRoomMemberEvent},
                message::{MessageType, RoomMessageEventContent, SyncRoomMessageEvent},
            },
        },
        room::JoinRule,
        serde::Raw,
        OwnedDeviceId, OwnedRoomId, OwnedTransactionId, OwnedUserId,
    },
    store::StateStoreDataKey,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Mutex;

const HOMESERVER: &str = "http://127.0.0.1:8008";
const ADMIN_API: &str = "http://127.0.0.1:8008/_synapse/admin/v1/registration_tokens/new";
const INVITER: &str = "@odara:matrix.odarah.org";
const BOT_USER: &str = "@invite-bot:matrix.odarah.org";
const INVITE_BASE: &str = "https://cinny.matrix.odarah.org/register/matrix.odarah.org/?token=";
const CALL_BASE: &str = "https://guest.matrix.odarah.org/room/";
const MAIN_SERVER: &str = "matrix.odarah.org";
const GUEST_SERVER_SUFFIX: &str = ":guest.matrix.odarah.org";
const RTC_MEMBER_EVENT: &str = "org.matrix.msc3401.call.member";
const TOKEN_TTL_SECS: u64 = 24 * 60 * 60;
const MAX_ROOM_AGE_SECS: u64 = 12 * 60 * 60;
const RECONCILE_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Clone)]
struct App {
    http: reqwest::Client,
    access_token: Arc<str>,
    matrix: Client,
    calls: Arc<CallStore>,
    close_lock: Arc<Mutex<()>>,
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

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ManagedCall {
    created_at: u64,
    control_room_id: String,
}

type ManagedCalls = BTreeMap<String, ManagedCall>;

struct CallStore {
    path: PathBuf,
    calls: Mutex<ManagedCalls>,
}

impl CallStore {
    fn load(path: PathBuf) -> Result<Self> {
        let calls = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .with_context(|| format!("decode {}", path.display()))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
        };
        Ok(Self { path, calls: Mutex::new(calls) })
    }

    async fn snapshot(&self) -> ManagedCalls {
        self.calls.lock().await.clone()
    }

    async fn get(&self, room_id: &str) -> Option<ManagedCall> {
        self.calls.lock().await.get(room_id).cloned()
    }

    async fn insert(&self, room_id: String, call: ManagedCall) -> Result<()> {
        let mut calls = self.calls.lock().await;
        calls.insert(room_id, call);
        self.save(&calls)
    }

    async fn remove(&self, room_id: &str) -> Result<()> {
        let mut calls = self.calls.lock().await;
        calls.remove(room_id);
        self.save(&calls)
    }

    fn save(&self, calls: &ManagedCalls) -> Result<()> {
        let parent = self.path.parent().context("managed call state has no parent")?;
        fs::create_dir_all(parent)?;
        let temporary = self.path.with_extension("json.tmp");
        fs::write(&temporary, serde_json::to_vec_pretty(calls)?)?;
        fs::rename(&temporary, &self.path)?;
        Ok(())
    }
}

#[derive(Clone, Copy)]
enum CloseReason {
    Manual,
    MaxAge,
}

impl CloseReason {
    fn description(self) -> &'static str {
        match self {
            Self::Manual => "管理者のcloseコマンド",
            Self::MaxAge => "作成から12時間経過",
        }
    }
}

fn now_secs() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?
        .as_secs())
}

fn encode_fragment_component(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

fn call_url(name: &str, room_id: &str) -> String {
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("roomId", room_id)
        .append_pair("viaServers", MAIN_SERVER)
        .finish();
    format!("{CALL_BASE}#/{name}?{query}", name = encode_fragment_component(name))
}

fn parse_call_name(body: &str) -> Result<Option<&str>> {
    let Some(name) = body.strip_prefix("call create ") else {
        return Ok(None);
    };
    let name = name.trim();
    if name.is_empty() {
        bail!("通話名を指定してください: call create <通話名>");
    }
    if name.chars().count() > 100 || name.chars().any(char::is_control) {
        bail!("通話名は制御文字を含まない100文字以内にしてください");
    }
    Ok(Some(name))
}

fn parse_close_room(body: &str) -> Result<Option<OwnedRoomId>> {
    let Some(room_id) = body.strip_prefix("call close ") else {
        return Ok(None);
    };
    Ok(Some(room_id.trim().parse().context("call closeには有効なroom IDを指定してください")?))
}

async fn is_expected_dm(room: &Room) -> Result<bool> {
    let members = room.members(RoomMemberships::ACTIVE).await?;
    Ok(members.len() == 2
        && members.iter().any(|member| member.user_id().as_str() == INVITER)
        && members.iter().any(|member| member.user_id() == room.own_user_id()))
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
            create_registration_token(&room, &app).await?;
        } else if let Some(name) = parse_call_name(&text.body)? {
            create_call_room(&room, name, &app).await?;
        } else if let Some(room_id) = parse_close_room(&text.body)? {
            app.calls.get(room_id.as_str()).await
                .context("このroomはbotの管理対象ではありません")?;
            close_room(&app, &room_id, CloseReason::Manual).await?;
        }
        Ok(())
    }.await;

    if let Err(error) = result {
        eprintln!("bot request failed: {error:#}");
        room.send(RoomMessageEventContent::text_plain(
            "処理に失敗しました。詳細はbotのjournalを確認してください。",
        )).await.context("notify command failure")?;
    }
    Ok(())
}

async fn create_registration_token(room: &Room, app: &App) -> Result<()> {
    let requested_expiry_ms = now_secs()?
        .checked_add(TOKEN_TTL_SECS)
        .and_then(|seconds| seconds.checked_mul(1000))
        .context("expiry overflow")?;
    let response = app.http.post(ADMIN_API)
        .bearer_auth(app.access_token.as_ref())
        .json(&CreateTokenRequest { uses_allowed: 1, expiry_time: requested_expiry_ms, length: 32 })
        .send().await.context("call private registration-token API")?
        .error_for_status().context("registration-token API rejected request")?
        .json::<CreateTokenResponse>().await.context("decode registration-token response")?;
    if response.token.is_empty() {
        bail!("registration-token response omitted token");
    }

    let encoded: String = url::form_urlencoded::byte_serialize(response.token.as_bytes()).collect();
    let expiry = chrono::DateTime::from_timestamp_millis(requested_expiry_ms as i64)
        .context("invalid registration-token expiry")?;
    room.send(RoomMessageEventContent::text_plain(format!(
        "{INVITE_BASE}{encoded}\nExpires {}.", expiry.to_rfc3339()
    ))).await?;
    Ok(())
}

fn raw<T>(value: Value) -> Result<Raw<T>> {
    Raw::from_json_string(value.to_string()).context("encode raw Matrix event content")
}

async fn create_call_room(control_room: &Room, name: &str, app: &App) -> Result<()> {
    let inviter: OwnedUserId = INVITER.parse().context("invalid configured inviter")?;
    let initial_state: Vec<Raw<AnyInitialStateEvent>> = vec![
        raw(json!({
            "type": "m.room.encryption",
            "state_key": "",
            "content": { "algorithm": "m.megolm.v1.aes-sha2" }
        }))?,
        raw(json!({
            "type": "m.room.join_rules",
            "state_key": "",
            "content": { "join_rule": "invite" }
        }))?,
    ];
    let power_levels: Raw<RoomPowerLevelsContentOverride> = raw(json!({
        "ban": 50,
        "events": {
            "m.room.encryption": 100,
            "m.room.history_visibility": 100,
            "m.room.join_rules": 100,
            "m.room.name": 100,
            "m.room.power_levels": 100,
            "m.room.tombstone": 100,
            RTC_MEMBER_EVENT: 0
        },
        "events_default": 0,
        "invite": 100,
        "kick": 50,
        "redact": 50,
        "state_default": 100,
        "users": { BOT_USER: 100, INVITER: 50 },
        "users_default": 0
    }))?;
    let mut request = CreateRoomRequest::new();
    request.visibility = Visibility::Private;
    request.name = Some(name.to_owned());
    request.invite = vec![inviter];
    request.initial_state = initial_state;
    request.power_level_content_override = Some(power_levels);
    let call_room = app.matrix.create_room(request).await.context("create call room")?;
    let room_id = call_room.room_id();

    // Persist before changing invite-only to public, so an untracked room is never opened.
    let call = ManagedCall {
        created_at: now_secs()?,
        control_room_id: control_room.room_id().to_string(),
    };
    app.calls.insert(room_id.to_string(), call.clone()).await?;
    call_room.send_state_event(RoomJoinRulesEventContent::new(JoinRule::Public))
        .await.context("open newly created call room")?;

    let link = call_url(name, room_id.as_str());
    control_room.send(RoomMessageEventContent::text_plain(format!(
        "通話roomを作成しました。\n{link}\n\n閉じる: call close {room_id}"
    ))).await?;
    Ok(())
}

async fn close_room(app: &App, room_id: &OwnedRoomId, reason: CloseReason) -> Result<()> {
    let _guard = app.close_lock.lock().await;
    let Some(call) = app.calls.get(room_id.as_str()).await else {
        return Ok(());
    };
    let Some(room) = app.matrix.get_room(room_id) else {
        bail!("managed call room {room_id} is unavailable");
    };
    if room.state() == RoomState::Left {
        app.calls.remove(room_id.as_str()).await?;
        return Ok(());
    }

    room.send_state_event(RoomJoinRulesEventContent::new(JoinRule::Invite))
        .await.context("seal call room")?;
    // Fetch after sealing so a join accepted just before the change is not missed.
    for member in room.members(RoomMemberships::JOIN).await? {
        if member.user_id().as_str().ends_with(GUEST_SERVER_SUFFIX) {
            room.kick_user(member.user_id(), Some("Temporary call room closed"))
                .await.with_context(|| format!("remove guest {}", member.user_id()))?;
        }
    }

    let control_room_id: OwnedRoomId = call.control_room_id.parse()
        .context("invalid persisted control room ID")?;
    let dm = app.matrix.get_room(&control_room_id)
        .context("control DM room is unavailable")?;
    let txn_id: OwnedTransactionId = format!("call-close-{room_id}-{}", call.created_at).into();
    dm.send(RoomMessageEventContent::text_plain(format!(
        "通話room {room_id} を閉鎖しました（{}）。", reason.description()
    ))).with_transaction_id(txn_id).await.context("notify call room closure")?;
    room.leave().await.context("leave closed call room")?;
    app.calls.remove(room_id.as_str()).await?;
    Ok(())
}

async fn reconcile_all(app: &App) {
    let now = match now_secs() {
        Ok(now) => now,
        Err(error) => {
            eprintln!("failed to read clock while reconciling calls: {error:#}");
            return;
        }
    };
    for (room_id, call) in app.calls.snapshot().await {
        if now.saturating_sub(call.created_at) < MAX_ROOM_AGE_SECS {
            continue;
        }
        let result = async {
            let room_id: OwnedRoomId = room_id.parse().context("invalid managed room ID")?;
            close_room(app, &room_id, CloseReason::MaxAge).await
        }.await;
        if let Err(error) = result {
            eprintln!("failed to close expired call room {room_id}: {error:#}");
        }
    }
}

async fn reconcile_loop(app: App) {
    let mut interval = tokio::time::interval(RECONCILE_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        interval.tick().await;
        reconcile_all(&app).await;
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let access_token: Arc<str> = env::var("MATRIX_ACCESS_TOKEN")
        .context("MATRIX_ACCESS_TOKEN is not set")?.into();
    let device_id: OwnedDeviceId = env::var("MATRIX_DEVICE_ID")
        .context("MATRIX_DEVICE_ID is not set")?.into();
    let user_id: OwnedUserId = env::var("MATRIX_USER_ID")
        .context("MATRIX_USER_ID is not set")?.parse().context("invalid MATRIX_USER_ID")?;
    if user_id.as_str() != BOT_USER {
        bail!("MATRIX_USER_ID must be {BOT_USER}");
    }

    let state_dir = PathBuf::from(
        env::var("STATE_DIRECTORY").unwrap_or_else(|_| "/var/lib/matrix-invite-bot".to_owned()),
    );
    let calls = Arc::new(CallStore::load(state_dir.join("managed-calls.json"))?);
    let client = Client::builder()
        .homeserver_url(HOMESERVER)
        .sqlite_store(state_dir.join("matrix-sdk"), None)
        .build().await?;
    client.restore_session(MatrixSession {
        meta: SessionMeta { user_id: user_id.clone(), device_id: device_id.clone() },
        tokens: SessionTokens { access_token: access_token.to_string(), refresh_token: None },
    }).await?;
    let whoami = client.whoami().await.context("verify restored Matrix session")?;
    if whoami.user_id != user_id || whoami.device_id.as_ref() != Some(&device_id) || whoami.is_guest {
        bail!("restored Matrix session is not the configured dedicated bot device");
    }

    let app = App {
        http: reqwest::Client::builder().timeout(Duration::from_secs(15)).build()?,
        access_token,
        matrix: client.clone(),
        calls,
        close_lock: Arc::new(Mutex::new(())),
    };
    client.add_event_handler(handle_invite);

    let has_sync_token = client.state_store().get_kv_data(StateStoreDataKey::SyncToken)
        .await?.is_some();
    if !has_sync_token {
        client.sync_once(SyncSettings::default()).await?;
    }
    let message_app = app.clone();
    client.add_event_handler(move |event, room, encryption_info| {
        handle_message(event, room, encryption_info, message_app.clone())
    });

    tokio::spawn(reconcile_loop(app));
    client.sync(SyncSettings::default()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_call_commands() {
        assert_eq!(parse_call_name("call create Weekly call").unwrap(), Some("Weekly call"));
        assert_eq!(
            parse_close_room("call close !abc:matrix.odarah.org").unwrap().unwrap().as_str(),
            "!abc:matrix.odarah.org"
        );
        assert!(parse_call_name("call create   ").is_err());
        assert!(parse_close_room("call close nope").is_err());
    }

    #[test]
    fn generates_element_call_link() {
        assert_eq!(
            call_url("相談 会", "!abc:matrix.odarah.org"),
            "https://guest.matrix.odarah.org/room/#/%E7%9B%B8%E8%AB%87%20%E4%BC%9A?roomId=%21abc%3Amatrix.odarah.org&viaServers=matrix.odarah.org"
        );
    }
}
