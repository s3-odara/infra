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
const GUEST_ADMIN_API_BASE: &str = "http://10.77.3.17:8008/_synapse/admin/v1/registration_tokens";
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
    guest: Option<GuestRegistration>,
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

#[derive(Clone)]
struct GuestRegistration {
    http: reqwest::Client,
    admin_token: Arc<str>,
    /// Leaking it lets anyone register while the gate is meant to be closed.
    sentinel: Arc<str>,
}

impl GuestRegistration {
    /// The guest homeserver requires a token for all registrations once any
    /// valid one exists, so an undisclosed token closes registration and
    /// deleting it reopens it.
    async fn set_open(&self, open: bool) -> Result<()> {
        if open {
            self.delete_sentinel().await
        } else {
            self.create_sentinel().await
        }
    }

    async fn delete_sentinel(&self) -> Result<()> {
        let url = format!(
            "{GUEST_ADMIN_API_BASE}/{}",
            encode_fragment_component(self.sentinel.as_ref()),
        );
        let response = self.http.delete(url)
            .bearer_auth(self.admin_token.as_ref())
            .send()
            .await
            .context("guest registration-token delete request")?;
        // Accept only M_NOT_FOUND as "already open"; an unrouted request
        // also 404s with M_UNRECOGNIZED and must fail loudly.
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            let body = response.text().await.unwrap_or_default();
            if body.contains("M_NOT_FOUND") {
                return Ok(());
            }
            bail!("guest registration-token delete failed: HTTP 404: {body}");
        }
        response
            .error_for_status()
            .context("guest registration-token delete failed")?;
        Ok(())
    }

    async fn create_sentinel(&self) -> Result<()> {
        let response = self.http.post(format!("{GUEST_ADMIN_API_BASE}/new"))
            .bearer_auth(self.admin_token.as_ref())
            .json(&json!({
                "token": self.sentinel.as_ref(),
                "uses_allowed": None::<u32>,
                "expiry_time": None::<u64>,
            }))
            .send()
            .await
            .context("guest registration-token create request")?;
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        // A duplicate means the gate is already closed; any other 400 is a
        // real failure.
        if status == reqwest::StatusCode::BAD_REQUEST && body.contains("already exists") {
            return Ok(());
        }
        if !status.is_success() {
            bail!("guest registration-token create failed: HTTP {status}: {body}");
        }
        Ok(())
    }
}

async fn settle_guest_registration(app: &App, dm: Option<&Room>) {
    if app.calls.snapshot().await.is_empty()
        && let Err(error) = set_guest_registration(app, false).await
    {
        eprintln!("failed to close guest registration: {error:#}");
        if let Some(dm) = dm {
            let _ = dm.send(RoomMessageEventContent::text_plain(
                "注意: guest homeserverの登録閉鎖に失敗しました。",
            )).await;
        }
    }
}

async fn set_guest_registration(app: &App, open: bool) -> Result<()> {
    match &app.guest {
        Some(registration) => registration.set_open(open).await,
        None => Ok(()),
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
    // Held by both create and close, so a racing close cannot re-create the
    // sentinel after the create deleted it, stranding an existing room behind
    // a closed gate.
    let _guard = app.close_lock.lock().await;
    // Delete is idempotent, so no emptiness check: opening unconditionally
    // also reaps a gate a failed close left open.
    set_guest_registration(app, true).await
        .context("guest homeserverの登録を開放できませんでした")?;

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
        let dm = call.control_room_id.parse::<OwnedRoomId>().ok()
            .and_then(|room_id| app.matrix.get_room(&room_id));
        settle_guest_registration(app, dm.as_ref()).await;
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
    settle_guest_registration(app, Some(&dm)).await;
    Ok(())
}

async fn reconcile_all(app: &App) {
    // Heals a gate left open by a failed close or a failed create. The lock
    // keeps the empty-store check from racing a create between its gate-open
    // and store insert.
    {
        let _guard = app.close_lock.lock().await;
        settle_guest_registration(app, None).await;
    }

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

    let http = reqwest::Client::builder().timeout(Duration::from_secs(15)).build()?;
    let registration = match (env::var("GUEST_ADMIN_ACCESS_TOKEN"), env::var("GUEST_SENTINEL_TOKEN")) {
        (Ok(token), Ok(sentinel)) if !token.is_empty() && !sentinel.is_empty() => {
            Some(GuestRegistration {
                http: http.clone(),
                admin_token: token.into(),
                sentinel: sentinel.into(),
            })
        }
        _ => {
            eprintln!(
                "guest registration gating is disabled: set GUEST_ADMIN_ACCESS_TOKEN and \
                 GUEST_SENTINEL_TOKEN to enable it"
            );
            None
        }
    };

    let app = App {
        http,
        access_token,
        matrix: client.clone(),
        calls,
        close_lock: Arc::new(Mutex::new(())),
        guest: registration,
    };

    // Opening when managed calls already exist happens only here and on call
    // create; the reconcile loop only ever closes the gate.
    if let Err(error) = set_guest_registration(&app, !app.calls.snapshot().await.is_empty()).await {
        eprintln!("failed to reconcile guest registration on startup: {error:#}");
    }
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
    fn leaves_url_safe_sentinel_tokens_untouched() {
        assert_eq!(encode_fragment_component("abc123XYZ"), "abc123XYZ");
    }

    #[test]
    fn generates_element_call_link() {
        assert_eq!(
            call_url("相談 会", "!abc:matrix.odarah.org"),
            "https://guest.matrix.odarah.org/room/#/%E7%9B%B8%E8%AB%87%20%E4%BC%9A?roomId=%21abc%3Amatrix.odarah.org&viaServers=matrix.odarah.org"
        );
    }
}
