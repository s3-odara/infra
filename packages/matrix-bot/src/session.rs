//! Startup checks around the SDK's normal persistent-store/session lifecycle.

use std::{collections::BTreeMap, fs, io::ErrorKind, path::Path, time::Duration};

use anyhow::{Context, Result, bail, ensure};
use matrix_sdk::{
    Client, SqliteCryptoStore,
    authentication::matrix::MatrixSession,
    config::SyncSettings,
    ruma::{OwnedDeviceId, OwnedUserId, serde::Raw},
};
use matrix_sdk_crypto::{store::CryptoStore, types::DeviceKeys, vodozemac::olm::IdentityKeys};
use serde::Deserialize;
use serde_json::{Value, json};

const CRYPTO_DATABASE: &str = "matrix-sdk-crypto.sqlite3";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StartupMode {
    Restore,
    Initialize,
}

impl StartupMode {
    pub(crate) fn parse(args: &[String]) -> Result<Option<Self>> {
        match args {
            [] => Ok(Some(Self::Restore)),
            [arg] if arg == "--initialize-crypto-store" => Ok(Some(Self::Initialize)),
            [arg] if arg == "--help" || arg == "-h" => Ok(None),
            _ => bail!("usage: matrix-bot [--initialize-crypto-store]"),
        }
    }
}

#[derive(Deserialize)]
struct WhoAmI {
    user_id: OwnedUserId,
    device_id: Option<OwnedDeviceId>,
    #[serde(default)]
    is_guest: bool,
}

#[derive(Deserialize)]
struct KeyQuery {
    device_keys: BTreeMap<OwnedUserId, BTreeMap<OwnedDeviceId, Raw<DeviceKeys>>>,
    #[serde(default)]
    failures: BTreeMap<String, Value>,
}

fn check_session(whoami: &WhoAmI, session: &MatrixSession) -> Result<()> {
    ensure!(
        whoami.user_id == session.meta.user_id
            && whoami.device_id.as_ref() == Some(&session.meta.device_id)
            && !whoami.is_guest,
        "access token does not belong to the configured dedicated bot device"
    );
    Ok(())
}

fn server_keys(response: KeyQuery, session: &MatrixSession) -> Result<Option<IdentityKeys>> {
    ensure!(
        response.failures.is_empty(),
        "device-key query reported failures"
    );
    let Some(keys) = response
        .device_keys
        .get(&session.meta.user_id)
        .and_then(|devices| devices.get(&session.meta.device_id))
    else {
        return Ok(None);
    };
    // The SDK decodes key IDs and base64; do not duplicate its key parser.
    let keys = keys.deserialize().context("invalid device keys")?;
    ensure!(
        keys.user_id == session.meta.user_id && keys.device_id == session.meta.device_id,
        "device-key response names a different user or device"
    );
    Ok(Some(IdentityKeys {
        ed25519: keys.ed25519_key().context("missing Ed25519 key")?,
        curve25519: keys.curve25519_key().context("missing Curve25519 key")?,
    }))
}

async fn query_keys(
    http: &reqwest::Client,
    homeserver: &str,
    session: &MatrixSession,
) -> Result<Option<IdentityKeys>> {
    let body = json!({
        "device_keys": {session.meta.user_id.as_str(): [session.meta.device_id.as_str()]}
    });
    let response = http
        .post(format!("{homeserver}/_matrix/client/v3/keys/query"))
        .bearer_auth(&session.tokens.access_token)
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json::<KeyQuery>()
        .await?;
    server_keys(response, session)
}

fn check_keys(local: &IdentityKeys, server: &IdentityKeys) -> Result<()> {
    ensure!(
        local == server,
        "bot identity keys do not match the server; preserve the original store"
    );
    Ok(())
}

fn existing_crypto_database(path: &Path) -> Result<bool> {
    match fs::metadata(path.join(CRYPTO_DATABASE)) {
        Ok(metadata) => {
            ensure!(
                metadata.is_file() && metadata.len() > 0,
                "crypto database is empty or not a regular file"
            );
            Ok(true)
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).context("inspect crypto database"),
    }
}

fn fresh_store_directory(path: &Path) -> Result<bool> {
    match fs::read_dir(path) {
        Ok(mut entries) => Ok(entries.next().transpose()?.is_none()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error).context("inspect store directory"),
    }
}

async fn check_store(
    path: &Path,
    session: &MatrixSession,
    mode: StartupMode,
    server: Option<&IdentityKeys>,
) -> Result<()> {
    if !existing_crypto_database(path)? {
        ensure!(
            mode == StartupMode::Initialize && server.is_none(),
            "existing device requires its original crypto database"
        );
        ensure!(
            fresh_store_directory(path)?,
            "initialization requires a fresh store directory"
        );
        return Ok(()); // Only the SDK, during explicit initialization, creates it.
    }
    ensure!(
        mode == StartupMode::Initialize || server.is_some(),
        "server device has no registered keys"
    );
    // restore_session creates an account if missing, so inspect it first.
    let store = SqliteCryptoStore::open(path, None).await?;
    let account = store
        .load_account()
        .await?
        .context("saved crypto account is missing; refusing to generate replacement keys")?;
    ensure!(
        account.user_id() == session.meta.user_id && account.device_id() == session.meta.device_id,
        "crypto account belongs to a different user or device"
    );
    if let Some(server) = server {
        check_keys(&account.identity_keys(), server)?;
    }
    Ok(())
}

pub(crate) async fn restore_guarded(
    http: &reqwest::Client,
    homeserver: &str,
    path: &Path,
    session: MatrixSession,
    mode: StartupMode,
) -> Result<Client> {
    ensure!(
        mode == StartupMode::Initialize || existing_crypto_database(path)?,
        "crypto database is missing; restore the original store"
    );
    let whoami = http
        .get(format!("{homeserver}/_matrix/client/v3/account/whoami"))
        .bearer_auth(&session.tokens.access_token)
        .send()
        .await?
        .error_for_status()?
        .json::<WhoAmI>()
        .await?;
    check_session(&whoami, &session)?;
    let mut server = query_keys(http, homeserver, &session).await?;
    check_store(path, &session, mode, server.as_ref()).await?;

    // Let the SDK configure all stores and their locks, using the inspected path.
    let client = Client::builder()
        .homeserver_url(homeserver)
        .sqlite_store(path, None)
        .build()
        .await?;
    client.restore_session(session.clone()).await?;
    if mode == StartupMode::Initialize && server.is_none() {
        // Initial key upload only; application handlers are not registered yet.
        tokio::time::timeout(
            Duration::from_secs(60),
            client.sync_once(SyncSettings::default().timeout(Duration::ZERO)),
        )
        .await
        .context("crypto initialization timed out; preserve this store before retrying")??;
        server = query_keys(http, homeserver, &session).await?;
    }
    let keys = server.context("server device keys are missing after initialization")?;
    // Check the actual SDK account against the snapshot, without another query.
    let encryption = client.encryption();
    ensure!(
        encryption.ed25519_key().await == Some(keys.ed25519.to_base64())
            && encryption.curve25519_key().await == Some(keys.curve25519),
        "restored identity keys do not match the server; preserve the original store"
    );
    Ok(client)
}

#[cfg(test)]
mod tests;
