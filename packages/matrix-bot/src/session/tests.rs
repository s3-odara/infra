use super::*;
use matrix_sdk::{SessionMeta, SessionTokens, ruma::owned_user_id};
use matrix_sdk_crypto::{olm::Account, store::types::PendingChanges};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        loop {
            let path = std::env::temp_dir().join(format!(
                "matrix-bot-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create test directory: {error}"),
            }
        }
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn session() -> MatrixSession {
    MatrixSession {
        meta: SessionMeta {
            user_id: owned_user_id!("@bot:example.com"),
            device_id: "DEVICE".into(),
        },
        tokens: SessionTokens {
            access_token: "FIXTURE_TOKEN".into(),
            refresh_token: None,
        },
    }
}

async fn seed(path: &Path, meta: SessionMeta) -> IdentityKeys {
    let account = Account::with_device_id(&meta.user_id, &meta.device_id);
    let keys = account.identity_keys();
    SqliteCryptoStore::open(path, None)
        .await
        .unwrap()
        .save_pending_changes(PendingChanges {
            account: Some(account),
        })
        .await
        .unwrap();
    keys
}

async fn saved_keys(path: &Path) -> Option<IdentityKeys> {
    if !path.join(CRYPTO_DATABASE).exists() {
        return None;
    }
    SqliteCryptoStore::open(path, None)
        .await
        .unwrap()
        .load_account()
        .await
        .unwrap()
        .map(|account| account.identity_keys())
}

fn key_response(keys: Option<IdentityKeys>) -> Value {
    let devices = keys.map(|keys| json!({"DEVICE": {
        "user_id": "@bot:example.com", "device_id": "DEVICE", "algorithms": [], "signatures": {},
        "keys": {"ed25519:DEVICE": keys.ed25519.to_base64(), "curve25519:DEVICE": keys.curve25519.to_base64()}
    }})).unwrap_or_else(|| json!({}));
    json!({"device_keys": {"@bot:example.com": devices}})
}

struct Replies {
    whoami: Value,
    keys: Value,
}
struct Server {
    url: String,
    replies: Arc<Mutex<Replies>>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
impl Server {
    // Minimal Matrix peer for observable startup/upload behavior, not SDK internals.
    fn new(keys: Option<IdentityKeys>) -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let replies = Arc::new(Mutex::new(Replies {
            whoami: json!({"user_id": "@bot:example.com", "device_id": "DEVICE", "is_guest": false}),
            keys: key_response(keys),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let (state, done) = (replies.clone(), stop.clone());
        let worker = thread::spawn(move || {
            while !done.load(Ordering::Relaxed) {
                let (stream, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("test server: {error}"),
                };
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut reader = BufReader::new(stream);
                let mut request = String::new();
                if reader.read_line(&mut request).unwrap_or(0) == 0 {
                    continue;
                }
                let (mut length, mut authorized) = (0, false);
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
                        break;
                    }
                    if let Some((name, value)) = header.split_once(':') {
                        if name.eq_ignore_ascii_case("content-length") {
                            length = value.trim().parse().unwrap();
                        }
                        if name.eq_ignore_ascii_case("authorization") {
                            authorized = value.trim() == "Bearer FIXTURE_TOKEN";
                        }
                    }
                }
                let mut body = vec![0; length];
                if reader.read_exact(&mut body).is_err() {
                    continue;
                }
                let body: Value = if body.is_empty() {
                    Value::Null
                } else {
                    serde_json::from_slice(&body).unwrap()
                };
                let Some(target) = request.split_whitespace().nth(1) else {
                    continue;
                };
                let path = target.split('?').next().unwrap();
                let mut state = state.lock().unwrap();
                let (status, response) = if !authorized && !path.ends_with("/versions") {
                    (
                        401,
                        json!({"errcode": "M_UNKNOWN_TOKEN", "error": "Fixture token required"}),
                    )
                } else if path.ends_with("/account/whoami") {
                    (200, state.whoami.clone())
                } else if path.ends_with("/keys/query") {
                    (200, state.keys.clone())
                } else if path.ends_with("/keys/upload") {
                    if let Some(keys) = body.get("device_keys") {
                        state.keys = json!({"device_keys": {"@bot:example.com": {"DEVICE": keys}}});
                    }
                    (
                        200,
                        json!({"one_time_key_counts": {"signed_curve25519": 50}}),
                    )
                } else if path.ends_with("/versions") {
                    (200, json!({"versions": ["v1.11"]}))
                } else if path.ends_with("/sync") {
                    (
                        200,
                        json!({"next_batch": "fixture", "rooms": {}, "to_device": {"events": []}, "device_one_time_keys_count": {"signed_curve25519": 50}}),
                    )
                } else {
                    (
                        404,
                        json!({"errcode": "M_NOT_FOUND", "error": "Fixture resource missing"}),
                    )
                };
                let body = response.to_string();
                // SDK background requests may be cancelled when the test drops a client.
                let _ = write!(
                    reader.get_mut(),
                    "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        Self {
            url,
            replies,
            stop,
            worker: Some(worker),
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let result = self.worker.take().unwrap().join();
        if !thread::panicking() {
            result.unwrap();
        }
    }
}

async fn restore(server: &Server, path: &Path, mode: StartupMode) -> Result<Client> {
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .unwrap();
    tokio::time::timeout(
        Duration::from_secs(15),
        restore_guarded(&http, &server.url, path, session(), mode),
    )
    .await
    .expect("startup timed out")
}

async fn reject(server: &Server, path: &Path, mode: StartupMode) {
    let before = saved_keys(path).await;
    let registered = server.replies.lock().unwrap().keys.clone();
    assert!(restore(server, path, mode).await.is_err());
    assert_eq!(saved_keys(path).await, before);
    assert_eq!(server.replies.lock().unwrap().keys, registered);
}

#[test]
fn only_the_explicit_flag_selects_initialization() {
    assert_eq!(StartupMode::parse(&[]).unwrap(), Some(StartupMode::Restore));
    assert_eq!(
        StartupMode::parse(&["--initialize-crypto-store".into()]).unwrap(),
        Some(StartupMode::Initialize)
    );
    assert!(StartupMode::parse(&["--force".into()]).is_err());
}

#[tokio::test]
async fn unusable_stores_are_rejected_without_generating_or_replacing_keys() {
    for case in ["absent", "no-account", "wrong-user", "wrong-device"] {
        for mode in [StartupMode::Restore, StartupMode::Initialize] {
            let dir = Directory::new();
            let path = dir.0.join("store");
            let mut meta = session().meta;
            let before = match case {
                "absent" => None,
                "no-account" => {
                    SqliteCryptoStore::open(&path, None).await.unwrap();
                    None
                }
                _ => {
                    if case == "wrong-user" {
                        meta.user_id = owned_user_id!("@other:example.com");
                    }
                    if case == "wrong-device" {
                        meta.device_id = "OTHER".into();
                    }
                    Some(seed(&path, meta).await)
                }
            };
            let remote = before.unwrap_or_else(|| {
                Account::with_device_id(&session().meta.user_id, &session().meta.device_id)
                    .identity_keys()
            });
            let server = Server::new(Some(remote));
            reject(&server, &path, mode).await;
        }
    }
}

#[tokio::test]
async fn credential_or_public_key_mismatches_reject_startup_and_preserve_identity() {
    let dir = Directory::new();
    let keys = seed(&dir.0, session().meta).await;
    let other =
        Account::with_device_id(&session().meta.user_id, &session().meta.device_id).identity_keys();
    let server = Server::new(Some(keys));
    let whoami = server.replies.lock().unwrap().whoami.clone();
    let mut cases = Vec::new();
    for (field, value) in [
        ("user_id", json!("@other:example.com")),
        ("device_id", json!("OTHER")),
        ("device_id", Value::Null),
        ("is_guest", json!(true)),
    ] {
        let mut wrong = whoami.clone();
        wrong[field] = value;
        cases.push((wrong, key_response(Some(keys))));
    }
    for wrong in [
        IdentityKeys {
            ed25519: other.ed25519,
            ..keys
        },
        IdentityKeys {
            curve25519: other.curve25519,
            ..keys
        },
    ] {
        cases.push((whoami.clone(), key_response(Some(wrong))));
    }
    for (whoami, response) in cases {
        for mode in [StartupMode::Restore, StartupMode::Initialize] {
            *server.replies.lock().unwrap() = Replies {
                whoami: whoami.clone(),
                keys: response.clone(),
            };
            reject(&server, &dir.0, mode).await;
        }
    }
}

#[tokio::test]
async fn initialization_does_not_reset_existing_or_ambiguous_state() {
    let dir = Directory::new();
    let server = Server::new(None);
    let empty_account = dir.0.join("empty-account");
    SqliteCryptoStore::open(&empty_account, None).await.unwrap();
    reject(&server, &empty_account, StartupMode::Initialize).await;
    let nonempty = dir.0.join("nonempty");
    fs::create_dir(&nonempty).unwrap();
    fs::write(nonempty.join("keep"), "KEEP").unwrap();
    reject(&server, &nonempty, StartupMode::Initialize).await;
    assert_eq!(fs::read_to_string(nonempty.join("keep")).unwrap(), "KEEP");
    let fresh = dir.0.join("fresh");
    for response in [
        json!({}),
        json!({"device_keys": {}, "failures": {"example.com": {}}}),
        json!({"device_keys": {"@bot:example.com": {"DEVICE": {"keys": {}}}}}),
    ] {
        server.replies.lock().unwrap().keys = response;
        reject(&server, &fresh, StartupMode::Initialize).await;
    }
}

#[tokio::test]
async fn normal_start_initialization_and_upload_resume_keep_identity_across_restarts() {
    for (existing, registered) in [(true, true), (false, false), (true, false)] {
        let dir = Directory::new();
        let path = dir.0.join("store");
        let original = if existing {
            Some(seed(&path, session().meta).await)
        } else {
            None
        };
        let server = Server::new(if registered { original } else { None });
        if !registered {
            reject(&server, &path, StartupMode::Restore).await;
        }
        let mode = if registered {
            StartupMode::Restore
        } else {
            StartupMode::Initialize
        };
        let client = restore(&server, &path, mode).await.unwrap();
        let keys = saved_keys(&path).await.unwrap();
        if let Some(original) = original {
            assert_eq!(keys, original);
        }
        assert_eq!(
            client.encryption().ed25519_key().await,
            Some(keys.ed25519.to_base64())
        );
        assert_eq!(
            client.encryption().curve25519_key().await,
            Some(keys.curve25519)
        );
        {
            let replies = server.replies.lock().unwrap();
            let published = &replies.keys["device_keys"]["@bot:example.com"]["DEVICE"]["keys"];
            assert_eq!(published["ed25519:DEVICE"], keys.ed25519.to_base64());
            assert_eq!(published["curve25519:DEVICE"], keys.curve25519.to_base64());
        }
        drop(client);
        let client = restore(&server, &path, StartupMode::Restore).await.unwrap();
        assert_eq!(
            client.encryption().ed25519_key().await,
            Some(keys.ed25519.to_base64())
        );
        assert_eq!(
            client.encryption().curve25519_key().await,
            Some(keys.curve25519)
        );
        drop(client);
        assert_eq!(saved_keys(&path).await, Some(keys));
    }
}
