use std::{collections::BTreeMap, fs, io::Write, path::Path, path::PathBuf, process::Command};

use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, prelude::BASE64_STANDARD};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use tempfile::NamedTempFile;

const LOCK_NAMES: [&str; 4] = ["jaeger-client", "opentracing", "pywebpush", "twisted"];
const SDIST_SUFFIXES: [&str; 3] = [".tar.gz", ".tar.bz2", ".zip"];

#[derive(Deserialize)]
struct PoetryLock {
    package: Vec<LockEntry>,
}

// Keep all upstream fields for the report; only pin comparison needs a schema.
#[derive(Deserialize, Serialize)]
struct LockEntry {
    name: String,
    #[serde(flatten)]
    fields: toml::Table,
}

#[derive(Deserialize)]
struct LockedPackage {
    version: String,
    files: Vec<LockedFile>,
}

#[derive(Deserialize)]
struct LockedFile {
    file: String,
    hash: String,
}

#[derive(Deserialize)]
struct Pins {
    python: BTreeMap<String, Pin>,
}

#[derive(Deserialize)]
struct Pin {
    version: String,
    hash: String,
}

// PEP 503 normalization for ASCII Python distribution names.
fn normalize(name: &str) -> String {
    let mut normalized = String::new();
    for ch in name.chars() {
        if matches!(ch, '-' | '_' | '.') {
            if !normalized.ends_with('-') {
                normalized.push('-');
            }
        } else {
            normalized.push(ch.to_ascii_lowercase());
        }
    }
    normalized
}

fn load_toml<T: DeserializeOwned>(path: &Path) -> Result<T> {
    let text = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    toml::from_str(&text).with_context(|| format!("parse {}", path.display()))
}

fn lock_entries(path: &Path) -> Result<BTreeMap<String, LockEntry>> {
    let lock: PoetryLock = load_toml(path)?;
    let mut selected = BTreeMap::new();
    for package in lock.package {
        let name = normalize(&package.name);
        if LOCK_NAMES.contains(&name.as_str()) {
            ensure!(
                selected.insert(name.clone(), package).is_none(),
                "duplicate normalized lock package: {name}"
            );
        }
    }
    Ok(selected)
}

fn constraints(path: &Path) -> Result<BTreeMap<String, toml::Value>> {
    let project: toml::Value = load_toml(path)?;
    let dependencies = project
        .get("tool")
        .and_then(|tool| tool.get("poetry"))
        .and_then(|poetry| poetry.get("dependencies"))
        .and_then(toml::Value::as_table)
        .with_context(|| format!("{}: missing [tool.poetry.dependencies]", path.display()))?;
    let mut selected = BTreeMap::new();
    for (source_name, value) in dependencies {
        let name = normalize(source_name);
        if LOCK_NAMES.contains(&name.as_str())
            || ["aioapns", "prometheus-client"].contains(&name.as_str())
        {
            ensure!(
                selected.insert(name.clone(), value.clone()).is_none(),
                "duplicate normalized dependency constraint: {name}"
            );
        }
    }
    Ok(selected)
}

fn formatted(value: &impl Serialize) -> Result<String> {
    // serde_json::Value sorts object keys, including flattened/nested metadata.
    Ok(serde_json::to_string_pretty(&serde_json::to_value(value)?)? + "\n")
}

fn show_diff(label: &str, before: &impl Serialize, after: &impl Serialize) -> Result<()> {
    println!("\n==> Selected upstream {label} changes");
    let before = formatted(before)?;
    let after = formatted(after)?;
    if before == after {
        println!("(no selected changes)");
        return Ok(());
    }
    let mut old = NamedTempFile::new()?;
    let mut new = NamedTempFile::new()?;
    old.write_all(before.as_bytes())?;
    new.write_all(after.as_bytes())?;
    // Flush the heading before the child inherits stdout. Nix pins diff's path.
    std::io::stdout().flush()?;
    let status = Command::new(option_env!("DIFF").unwrap_or("diff"))
        .args(["-u", "--label", &format!("old/{label}.json")])
        .args(["--label", &format!("new/{label}.json")])
        .arg(old.path())
        .arg(new.path())
        .status()
        .context("run diff")?;
    ensure!(
        matches!(status.code(), Some(0 | 1)),
        "diff failed: {status}"
    );
    Ok(())
}

fn check_pins(path: &Path, lock: &BTreeMap<String, LockEntry>) -> Result<()> {
    let pins: Pins = serde_json::from_slice(
        &fs::read(path).with_context(|| format!("read {}", path.display()))?,
    )
    .with_context(|| format!("parse {}", path.display()))?;
    let pins: BTreeMap<_, _> = pins
        .python
        .into_iter()
        .map(|(name, pin)| (normalize(&name), pin))
        .collect();
    ensure!(
        pins.keys().map(String::as_str).eq(LOCK_NAMES),
        "pins.json must contain exactly the four handwritten Python pins"
    );
    let missing: Vec<_> = LOCK_NAMES
        .into_iter()
        .filter(|name| !lock.contains_key(*name))
        .collect();
    ensure!(
        missing.is_empty(),
        "new poetry.lock is missing handwritten pins: {}",
        missing.join(", ")
    );
    for name in LOCK_NAMES {
        let package: LockedPackage = toml::Value::Table(lock[name].fields.clone())
            .try_into()
            .with_context(|| format!("{name}: invalid locked package"))?;
        let pin = &pins[name];
        let sdists: Vec<_> = package
            .files
            .iter()
            .filter(|entry| {
                SDIST_SUFFIXES
                    .iter()
                    .any(|suffix| entry.file.ends_with(suffix))
            })
            .collect();
        ensure!(
            sdists.len() == 1,
            "{name}: expected exactly one locked sdist, found {}",
            sdists.len()
        );
        let sdist = sdists[0];
        let lock_hash = sdist
            .hash
            .strip_prefix("sha256:")
            .with_context(|| format!("{name}: locked sdist does not use SHA-256"))?;
        let pin_hash = pin
            .hash
            .strip_prefix("sha256-")
            .with_context(|| format!("{name}: handwritten pin does not use SHA-256 SRI"))?;
        let lock_digest =
            hex::decode(lock_hash).with_context(|| format!("{name}: invalid lock hash"))?;
        let pin_digest = BASE64_STANDARD
            .decode(pin_hash)
            .with_context(|| format!("{name}: invalid handwritten hash"))?;
        ensure!(
            pin.version == package.version && pin_digest == lock_digest,
            "{name}: handwritten pin mismatch; pin={} {}, lock={} {} {}",
            pin.version,
            pin.hash,
            package.version,
            sdist.file,
            sdist.hash
        );
        println!(
            "pin ok: {name} {} {} {}",
            package.version, sdist.file, sdist.hash
        );
    }
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let [old_lock, old_project, new_lock, new_project, pins] = args.as_slice() else {
        bail!("usage: check-sygnal-pins OLD_LOCK OLD_PYPROJECT NEW_LOCK NEW_PYPROJECT PINS_JSON");
    };
    let old_lock = lock_entries(old_lock)?;
    let old_constraints = constraints(old_project)?;
    let new_lock = lock_entries(new_lock)?;
    let new_constraints = constraints(new_project)?;
    show_diff("poetry-lock", &old_lock, &new_lock)?;
    show_diff("pyproject-constraints", &old_constraints, &new_constraints)?;
    check_pins(pins, &new_lock)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("check-sygnal-pins: {error:#}");
        std::process::exit(1);
    }
}
