use std::{collections::BTreeMap, fs, path::PathBuf, sync::Arc, time::Duration};

use anyhow::{Context, Result, bail};
use matrix_sdk::{
    Client, Room, RoomMemberships, RoomState,
    ruma::{
        OwnedRoomId, OwnedTransactionId, OwnedUserId,
        api::client::room::{
            Visibility,
            create_room::{RoomPowerLevelsContentOverride, v3::Request as CreateRoomRequest},
        },
        events::{
            AnyInitialStateEvent,
            room::{join_rules::RoomJoinRulesEventContent, message::RoomMessageEventContent},
        },
        room::JoinRule,
        serde::Raw,
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::{BOT_USER, INVITER, now_secs};

const ADMIN_ROOMS_API: &str = "http://127.0.0.1:8008/_synapse/admin/v1/rooms";
const GUEST_ADMIN_API_BASE: &str = "http://10.77.3.17:8008/_synapse/admin/v1/registration_tokens";
const GUEST_ADMIN_USERS_API: &str = "http://10.77.3.17:8008/_synapse/admin/v3/users?limit=100&admins=false&deactivated=false&locked=true";
const GUEST_ADMIN_DEACTIVATE_API: &str = "http://10.77.3.17:8008/_synapse/admin/v1/deactivate";
const CALL_BASE: &str = "https://guest.matrix.odarah.org/room/";
const MAIN_SERVER: &str = "matrix.odarah.org";
const GUEST_SERVER_SUFFIX: &str = ":guest.matrix.odarah.org";
const RTC_MEMBER_EVENT: &str = "org.matrix.msc3401.call.member";
const MAX_ROOM_AGE_SECS: u64 = 12 * 60 * 60;
const RECONCILE_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub(crate) struct CallService {
    http: reqwest::Client,
    access_token: Arc<str>,
    matrix: Client,
    calls: Arc<CallStore>,
    close_lock: Arc<Mutex<()>>,
    guest: Option<GuestRegistration>,
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
        Ok(Self {
            path,
            calls: Mutex::new(calls),
        })
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
        let parent = self
            .path
            .parent()
            .context("managed call state has no parent")?;
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
    /// Must stay secret because it authorizes registration while the gate is closed.
    sentinel: Arc<str>,
}

impl GuestRegistration {
    /// A secret valid token makes all guest registrations require that token.
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
        let response = self
            .http
            .delete(url)
            .bearer_auth(self.admin_token.as_ref())
            .send()
            .await
            .context("guest registration-token delete request")?;
        // A bad route also returns 404; only M_NOT_FOUND means already open.
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
        let response = self
            .http
            .post(format!("{GUEST_ADMIN_API_BASE}/new"))
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
        // Only a duplicate means already closed.
        if status == reqwest::StatusCode::BAD_REQUEST && body.contains("already exists") {
            return Ok(());
        }
        if !status.is_success() {
            bail!("guest registration-token create failed: HTTP {status}: {body}");
        }
        Ok(())
    }

    async fn deactivate_non_admin_users(&self) -> Result<()> {
        loop {
            // Deactivation shrinks this result, so repeatedly read page one.
            let page = self
                .http
                .get(GUEST_ADMIN_USERS_API)
                .bearer_auth(self.admin_token.as_ref())
                .send()
                .await
                .context("guest user-list request")?
                .error_for_status()
                .context("guest user-list API rejected request")?
                .json::<GuestUsersPage>()
                .await
                .context("decode guest user-list response")?;
            if page.users.is_empty() {
                return Ok(());
            }
            for user in page.users {
                let url = format!(
                    "{GUEST_ADMIN_DEACTIVATE_API}/{}",
                    encode_fragment_component(&user.name),
                );
                self.http
                    .post(url)
                    .bearer_auth(self.admin_token.as_ref())
                    .json(&json!({ "erase": true }))
                    .send()
                    .await
                    .with_context(|| format!("deactivate guest user {}", user.name))?
                    .error_for_status()
                    .with_context(|| {
                        format!("guest user deactivation rejected for {}", user.name)
                    })?;
            }
        }
    }
}

#[derive(Deserialize)]
struct GuestUsersPage {
    users: Vec<GuestUser>,
}

#[derive(Deserialize)]
struct GuestUser {
    name: String,
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

impl CallService {
    pub(crate) fn load(
        matrix: Client,
        http: reqwest::Client,
        access_token: Arc<str>,
        state_path: PathBuf,
        guest_credentials: Option<(String, String)>,
    ) -> Result<Self> {
        let guest = guest_credentials.map(|(admin_token, sentinel)| GuestRegistration {
            http: http.clone(),
            admin_token: admin_token.into(),
            sentinel: sentinel.into(),
        });
        Ok(Self {
            http,
            access_token,
            matrix,
            calls: Arc::new(CallStore::load(state_path)?),
            close_lock: Arc::new(Mutex::new(())),
            guest,
        })
    }

    pub(crate) async fn is_managed(&self, room_id: &str) -> bool {
        self.calls.get(room_id).await.is_some()
    }

    pub(crate) async fn restore_guest_registration(&self) -> Result<()> {
        self.set_guest_registration(!self.calls.snapshot().await.is_empty())
            .await
    }

    pub(crate) async fn create(&self, control_room: &Room, name: &str) -> Result<()> {
        // Prevent close from restoring the sentinel while creation is in progress.
        let _guard = self.close_lock.lock().await;
        // Deletion is idempotent, so open unconditionally.
        self.set_guest_registration(true)
            .await
            .context("guest homeserverの登録を開放できませんでした")?;

        let inviter: OwnedUserId = INVITER.parse().context("invalid configured inviter")?;
        let initial_state: Vec<Raw<AnyInitialStateEvent>> = vec![
            raw(&json!({
                "type": "m.room.encryption",
                "state_key": "",
                "content": { "algorithm": "m.megolm.v1.aes-sha2" }
            }))?,
            raw(&json!({
                "type": "m.room.join_rules",
                "state_key": "",
                "content": { "join_rule": "invite" }
            }))?,
        ];
        let power_levels: Raw<RoomPowerLevelsContentOverride> = raw(&json!({
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
        let call_room = self
            .matrix
            .create_room(request)
            .await
            .context("create call room")?;
        let room_id = call_room.room_id();

        // Track before making the room public.
        let call = ManagedCall {
            created_at: now_secs()?,
            control_room_id: control_room.room_id().to_string(),
        };
        self.calls.insert(room_id.to_string(), call).await?;
        call_room
            .send_state_event(RoomJoinRulesEventContent::new(JoinRule::Public))
            .await
            .context("open newly created call room")?;

        let link = call_url(name, room_id.as_str());
        control_room
            .send(RoomMessageEventContent::text_plain(format!(
                "通話roomを作成しました。\n{link}\n\n閉じる: call close {room_id}"
            )))
            .await?;
        Ok(())
    }

    pub(crate) async fn close(&self, room_id: &OwnedRoomId) -> Result<()> {
        self.close_with_reason(room_id, CloseReason::Manual).await
    }

    async fn close_with_reason(&self, room_id: &OwnedRoomId, reason: CloseReason) -> Result<()> {
        let _guard = self.close_lock.lock().await;
        let Some(call) = self.calls.get(room_id.as_str()).await else {
            return Ok(());
        };
        let Some(room) = self.matrix.get_room(room_id) else {
            bail!("managed call room {room_id} is unavailable");
        };
        if room.state() == RoomState::Left {
            self.calls.remove(room_id.as_str()).await?;
            let dm = call
                .control_room_id
                .parse::<OwnedRoomId>()
                .ok()
                .and_then(|room_id| self.matrix.get_room(&room_id));
            self.settle_guest_registration(dm.as_ref()).await;
            return Ok(());
        }

        room.send_state_event(RoomJoinRulesEventContent::new(JoinRule::Invite))
            .await
            .context("seal call room")?;
        // Fetch after sealing so a join accepted just before the change is not missed.
        for member in room.members(RoomMemberships::JOIN).await? {
            if member.user_id().as_str().ends_with(GUEST_SERVER_SUFFIX) {
                room.kick_user(member.user_id(), Some("Temporary call room closed"))
                    .await
                    .with_context(|| format!("remove guest {}", member.user_id()))?;
            }
        }

        let control_room_id: OwnedRoomId = call
            .control_room_id
            .parse()
            .context("invalid persisted control room ID")?;
        let dm = self
            .matrix
            .get_room(&control_room_id)
            .context("control DM room is unavailable")?;
        let txn_id: OwnedTransactionId = format!("call-close-{room_id}-{}", call.created_at).into();
        room.leave().await.context("leave closed call room")?;
        // Deletion does not federate; keep tracking cleanup independent of this purge.
        if let Err(error) = self.delete_main_room(room_id).await {
            eprintln!("failed to purge closed call room {room_id}: {error:#}");
            let _ = dm
                .send(RoomMessageEventContent::text_plain(
                    "注意: 閉鎖したroomのデータ削除に失敗しました。",
                ))
                .await;
        }
        self.calls.remove(room_id.as_str()).await?;
        self.settle_guest_registration(Some(&dm)).await;
        let _ = dm
            .send(RoomMessageEventContent::text_plain(format!(
                "通話room {room_id} を閉鎖しました（{}）。",
                reason.description()
            )))
            .with_transaction_id(txn_id)
            .await;
        Ok(())
    }

    pub(crate) async fn reconcile_loop(self) {
        let mut interval = tokio::time::interval(RECONCILE_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            self.reconcile_all().await;
        }
    }

    async fn reconcile_all(&self) {
        // Do not close the gate between a concurrent create's open and insert.
        {
            let _guard = self.close_lock.lock().await;
            self.settle_guest_registration(None).await;
        }

        let now = match now_secs() {
            Ok(now) => now,
            Err(error) => {
                eprintln!("failed to read clock while reconciling calls: {error:#}");
                return;
            }
        };
        for (room_id, call) in self.calls.snapshot().await {
            if now.saturating_sub(call.created_at) < MAX_ROOM_AGE_SECS {
                continue;
            }
            let result = async {
                let room_id: OwnedRoomId = room_id.parse().context("invalid managed room ID")?;
                self.close_with_reason(&room_id, CloseReason::MaxAge).await
            }
            .await;
            if let Err(error) = result {
                eprintln!("failed to close expired call room {room_id}: {error:#}");
            }
        }
    }

    async fn delete_main_room(&self, room_id: &OwnedRoomId) -> Result<()> {
        // v1 purges synchronously by default.
        let url = format!(
            "{ADMIN_ROOMS_API}/{}",
            encode_fragment_component(room_id.as_str()),
        );
        self.http
            .delete(url)
            .bearer_auth(self.access_token.as_ref())
            .json(&json!({}))
            .send()
            .await
            .context("call purge-room API")?
            .error_for_status()
            .context("purge-room API rejected request")?;
        Ok(())
    }

    async fn settle_guest_registration(&self, dm: Option<&Room>) {
        if !self.calls.snapshot().await.is_empty() {
            return;
        }
        if let Err(error) = self.set_guest_registration(false).await {
            eprintln!("failed to close guest registration: {error:#}");
            if let Some(dm) = dm {
                let _ = dm
                    .send(RoomMessageEventContent::text_plain(
                        "注意: guest homeserverの登録閉鎖に失敗しました。",
                    ))
                    .await;
            }
            return;
        }
        if let Some(registration) = &self.guest
            && let Err(error) = registration.deactivate_non_admin_users().await
        {
            eprintln!("failed to deactivate guest users: {error:#}");
            if let Some(dm) = dm {
                let _ = dm
                    .send(RoomMessageEventContent::text_plain(
                        "注意: guest accountの無効化に失敗しました。",
                    ))
                    .await;
            }
        }
    }

    async fn set_guest_registration(&self, open: bool) -> Result<()> {
        match &self.guest {
            Some(registration) => registration.set_open(open).await,
            None => Ok(()),
        }
    }
}

pub(crate) fn parse_call_name(body: &str) -> Result<Option<&str>> {
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

pub(crate) fn parse_close_room(body: &str) -> Result<Option<OwnedRoomId>> {
    let Some(room_id) = body.strip_prefix("call close ") else {
        return Ok(None);
    };
    Ok(Some(room_id.trim().parse().context(
        "call closeには有効なroom IDを指定してください",
    )?))
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
    format!(
        "{CALL_BASE}#/{name}?{query}",
        name = encode_fragment_component(name)
    )
}

fn raw<T>(value: &Value) -> Result<Raw<T>> {
    Raw::from_json_string(value.to_string()).context("encode raw Matrix event content")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_call_commands() {
        assert_eq!(
            parse_call_name("call create Weekly call").unwrap(),
            Some("Weekly call")
        );
        assert_eq!(
            parse_close_room("call close !abc:matrix.odarah.org")
                .unwrap()
                .unwrap()
                .as_str(),
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
