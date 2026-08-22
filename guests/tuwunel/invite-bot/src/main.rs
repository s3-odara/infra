use std::{
    collections::BTreeMap,
    env,
    ffi::OsString,
    io::BufRead,
    path::PathBuf,
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
        api::client::{
            keys::get_keys,
            uiaa::{AuthData, Password},
        },
        encryption::{CrossSigningKey, KeyUsage},
        events::room::{
            member::{MembershipState, StrippedRoomMemberEvent},
            message::{MessageType, RoomMessageEventContent, SyncRoomMessageEvent},
        },
    },
    store::StateStoreDataKey,
};
use serde::{Deserialize, Serialize};
const HOMESERVER: &str = "http://127.0.0.1:8008";
const ADMIN_API: &str = "http://127.0.0.1:8008/_synapse/admin/v1/registration_tokens/new";
const INVITER: &str = "@odara:matrix.odarah.org";
const BOT_USER: &str = "@invite-bot:matrix.odarah.org";
const INVITE_BASE: &str = "https://cinny.matrix.odarah.org/register/matrix.odarah.org/?token=";
const TOKEN_TTL_SECS: u64 = 24 * 60 * 60;

#[derive(Debug, Eq, PartialEq)]
enum Mode {
    Service,
    BootstrapCrossSigning,
}

#[derive(Clone)]
struct App {
    http: reqwest::Client,
    access_token: Arc<str>,
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

fn parse_mode(args: impl IntoIterator<Item = OsString>) -> Result<Mode> {
    let args: Vec<_> = args.into_iter().collect();
    match args.as_slice() {
        [] => Ok(Mode::Service),
        [arg] if arg == "bootstrap-cross-signing" => Ok(Mode::BootstrapCrossSigning),
        _ => bail!("usage: matrix-invite-bot [bootstrap-cross-signing]"),
    }
}

fn read_password_line(mut input: impl BufRead) -> Result<String> {
    let mut password = String::new();
    let bytes_read = input
        .read_line(&mut password)
        .context("read bot password from stdin")?;
    if bytes_read == 0 {
        bail!("bot password was not provided on stdin");
    }
    if password.ends_with('\n') {
        password.pop();
        if password.ends_with('\r') {
            password.pop();
        }
    }
    if password.is_empty() {
        bail!("bot password must not be empty");
    }
    Ok(password)
}

fn now_secs() -> Result<u64> {
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

async fn restore_configured_session() -> Result<(Client, Arc<str>, OwnedUserId, OwnedDeviceId)> {
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

    Ok((client, access_token, user_id, device_id))
}

fn validate_server_cross_signing_key(
    key: CrossSigningKey,
    user_id: &OwnedUserId,
    expected_usage: KeyUsage,
) -> Result<()> {
    if key.user_id != *user_id {
        bail!("server returned a cross-signing key for an unexpected user");
    }
    if key.usage.len() != 1 || key.usage[0] != expected_usage {
        bail!("server returned a cross-signing key with inconsistent usage");
    }
    if key.keys.len() != 1 {
        bail!("server returned a cross-signing key without exactly one public key");
    }
    Ok(())
}

async fn server_cross_signing_identity_exists(
    client: &Client,
    user_id: &OwnedUserId,
) -> Result<bool> {
    let mut request = get_keys::v3::Request::new();
    request.device_keys = BTreeMap::from([(user_id.clone(), Vec::new())]);
    let mut response = client
        .send(request)
        .await
        .context("query server-authoritative cross-signing keys")?;
    if !response.failures.is_empty() {
        bail!("server key query reported failures");
    }

    let master = response.master_keys.remove(user_id);
    let self_signing = response.self_signing_keys.remove(user_id);
    match (master, self_signing) {
        (None, None) => Ok(false),
        (Some(master), Some(self_signing)) => {
            validate_server_cross_signing_key(
                master.deserialize().context("decode server master key")?,
                user_id,
                KeyUsage::Master,
            )?;
            validate_server_cross_signing_key(
                self_signing
                    .deserialize()
                    .context("decode server self-signing key")?,
                user_id,
                KeyUsage::SelfSigning,
            )?;
            Ok(true)
        }
        _ => bail!("server returned an incomplete cross-signing identity"),
    }
}

async fn refresh_own_identity(client: &Client, user_id: &OwnedUserId) -> Result<bool> {
    Ok(client
        .encryption()
        .request_user_identity(user_id)
        .await
        .context("refresh own cross-signing identity")?
        .is_some())
}

async fn configured_device_is_cross_signed(
    client: &Client,
    user_id: &OwnedUserId,
    device_id: &OwnedDeviceId,
) -> Result<bool> {
    let device = client
        .encryption()
        .get_device(user_id, device_id)
        .await
        .context("read configured device from crypto store")?
        .context("configured device is absent from the crypto store after key query")?;
    Ok(device.is_cross_signed_by_owner())
}

async fn assert_configured_device_cross_signed(
    client: &Client,
    user_id: &OwnedUserId,
    device_id: &OwnedDeviceId,
) -> Result<()> {
    if !server_cross_signing_identity_exists(client, user_id).await? {
        bail!("server still has no cross-signing identity for the bot account");
    }
    if !refresh_own_identity(client, user_id).await? {
        bail!("server cross-signing identity was not refreshed into the crypto store");
    }
    if !configured_device_is_cross_signed(client, user_id, device_id).await? {
        bail!("configured device is still not cross-signed by the bot account");
    }
    Ok(())
}

async fn bootstrap_cross_signing(
    client: &Client,
    user_id: &OwnedUserId,
    device_id: &OwnedDeviceId,
) -> Result<()> {
    client
        .sync_once(SyncSettings::default())
        .await
        .context("initial sync for E2EE bootstrap")?;
    client
        .encryption()
        .wait_for_e2ee_initialization_tasks()
        .await;

    let identity_exists = server_cross_signing_identity_exists(client, user_id).await?;
    refresh_own_identity(client, user_id).await?;
    if identity_exists && configured_device_is_cross_signed(client, user_id, device_id).await? {
        assert_configured_device_cross_signed(client, user_id, device_id).await?;
        println!("configured Matrix device is already cross-signed by its owner");
        return Ok(());
    }

    if identity_exists {
        let status = client
            .encryption()
            .cross_signing_status()
            .await
            .context("E2EE machine is unavailable")?;
        if !status.has_self_signing {
            bail!(
                "a cross-signing identity already exists, but this store lacks its private self-signing key; refusing to reset or replace cross-signing"
            );
        }

        let device = client
            .encryption()
            .get_device(user_id, device_id)
            .await
            .context("read configured device from crypto store")?
            .context("configured device is absent from the crypto store after key query")?;
        device
            .verify()
            .await
            .context("sign configured device with existing self-signing key")?;
    } else {
        let uiaa = match client.encryption().bootstrap_cross_signing(None).await {
            Ok(()) => {
                assert_configured_device_cross_signed(client, user_id, device_id).await?;
                println!("cross-signing bootstrapped without an interactive-auth challenge");
                return Ok(());
            }
            Err(error) => error
                .as_uiaa_response()
                .cloned()
                .context("cross-signing bootstrap did not return a UIAA challenge")?,
        };
        let session = uiaa
            .session
            .context("cross-signing UIAA challenge omitted its session")?;

        let password = read_password_line(std::io::stdin().lock())?;
        let mut password_auth = Password::new(user_id.into(), password);
        password_auth.session = Some(session);
        client
            .encryption()
            .bootstrap_cross_signing(Some(AuthData::Password(password_auth)))
            .await
            .context("complete password-authenticated cross-signing bootstrap")?;
    }

    assert_configured_device_cross_signed(client, user_id, device_id).await?;
    println!("configured Matrix device is now cross-signed by its owner");
    Ok(())
}

async fn run_service(client: Client, access_token: Arc<str>) -> Result<()> {
    let app = App {
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .build()?,
        access_token,
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

#[tokio::main]
async fn main() -> Result<()> {
    let mode = parse_mode(env::args_os().skip(1))?;
    let (client, access_token, user_id, device_id) = restore_configured_session().await?;

    match mode {
        Mode::Service => run_service(client, access_token).await,
        Mode::BootstrapCrossSigning => bootstrap_cross_signing(&client, &user_id, &device_id).await,
    }
}

#[cfg(test)]
mod tests {
    use std::{ffi::OsString, io::Cursor};

    use super::{Mode, parse_mode, read_password_line};

    #[test]
    fn parses_supported_modes_and_refuses_other_arguments() {
        assert_eq!(parse_mode([]).unwrap(), Mode::Service);
        assert_eq!(
            parse_mode([OsString::from("bootstrap-cross-signing")]).unwrap(),
            Mode::BootstrapCrossSigning
        );
        assert!(parse_mode([OsString::from("unexpected")]).is_err());
        assert!(
            parse_mode([
                OsString::from("bootstrap-cross-signing"),
                OsString::from("extra")
            ])
            .is_err()
        );
    }

    #[test]
    fn reads_exactly_one_nonempty_password_line() {
        assert_eq!(
            read_password_line(Cursor::new(b"secret\nignored\n")).unwrap(),
            "secret"
        );
        assert_eq!(
            read_password_line(Cursor::new(b"spaces stay \r\n")).unwrap(),
            "spaces stay "
        );
        assert!(read_password_line(Cursor::new(b"\n")).is_err());
        assert!(read_password_line(Cursor::new(b"")).is_err());
    }
}
