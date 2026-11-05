use std::{fmt, fmt::Write as _, io::Write as _};

use anyhow::{Context, Result};
use tracing::{Event, Subscriber, field::Visit};
use tracing_subscriber::{filter::Targets, layer::Context as LayerContext, prelude::*};

pub(crate) fn init() -> Result<()> {
    tracing_subscriber::registry()
        .with(SdkDiagnostics.with_filter(sdk_targets()))
        .try_init()
        .context("initialize sanitized SDK diagnostics")
}

fn sdk_targets() -> Targets {
    Targets::new().with_target("matrix_sdk", tracing::Level::WARN)
}

struct SdkDiagnostics;

impl<S: Subscriber> tracing_subscriber::Layer<S> for SdkDiagnostics {
    fn on_event(&self, event: &Event<'_>, _: LayerContext<'_, S>) {
        let _ = writeln!(std::io::stderr().lock(), "{}", sdk_event(event));
    }
}

fn sdk_event(event: &Event<'_>) -> String {
    let mut fields = SafeFields::default();
    event.record(&mut fields);
    let metadata = event.metadata();
    format!(
        "sdk level={} target={} source={}:{} {}",
        metadata.level(),
        metadata.target(),
        metadata.file().unwrap_or("unknown"),
        metadata.line().unwrap_or(0),
        fields,
    )
}

pub(crate) fn error(context: &'static str, error: &impl fmt::Debug) {
    let mut fields = SafeFields::default();
    fields.inspect(error);
    eprintln!("bot event={context} {fields}");
}

#[derive(Default)]
struct SafeFields {
    category: Option<&'static str>,
    http_status: Option<u16>,
    matrix_code: Option<&'static str>,
}

impl SafeFields {
    fn inspect(&mut self, value: &impl fmt::Debug) {
        // Never emit arbitrary SDK fields, messages, URLs, or error bodies.
        // Only derive fixed labels and numeric HTTP statuses from bounded text.
        let mut text = BoundedText(String::new());
        let _ = write!(text, "{value:?}");
        let text = text.0.to_ascii_lowercase();
        let category = if (text.contains("one time key")
            || text.contains("one-time key")
            || text.contains("one_time_key"))
            && text.contains("already exists")
        {
            Some("duplicate_one_time_key")
        } else if text.contains("mismatchedidentitykeys") || text.contains("mismatched identity") {
            Some("identity_key_mismatch")
        } else if text.contains("signature") {
            Some("signature_error")
        } else if text.contains("sessionwedged") || text.contains("session wedged") {
            Some("olm_session_wedged")
        } else if text.contains("missingsession") || text.contains("missing session") {
            Some("missing_olm_session")
        } else if text.contains("missingroomkey") || text.contains("missingmegolmsession") {
            Some("missing_room_key")
        } else if text.contains("senderidentitynottrusted")
            || text.contains("unverifiedsenderdevice")
        {
            Some("sender_not_trusted")
        } else {
            None
        };
        if category.is_some() {
            self.category = category;
        }
        for (needle, code) in [
            ("unknown_token", "M_UNKNOWN_TOKEN"),
            ("unknowntoken", "M_UNKNOWN_TOKEN"),
            ("forbidden", "M_FORBIDDEN"),
            ("unauthorized", "M_UNAUTHORIZED"),
            ("limitexceeded", "M_LIMIT_EXCEEDED"),
            ("limit_exceeded", "M_LIMIT_EXCEEDED"),
            ("invalidparam", "M_INVALID_PARAM"),
            ("invalid_param", "M_INVALID_PARAM"),
            ("badjson", "M_BAD_JSON"),
            ("bad_json", "M_BAD_JSON"),
        ] {
            if text.contains(needle) {
                self.matrix_code = Some(code);
                break;
            }
        }
        for marker in ["status_code: ", "status: ", "status code ", "http "] {
            if let Some((_, rest)) = text.split_once(marker)
                && let Some(digits) = rest.get(..3)
                && let Ok(status @ 400..=599) = digits.parse::<u16>()
            {
                self.http_status = Some(status);
                break;
            }
        }
    }
}

impl Visit for SafeFields {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn fmt::Debug) {
        if matches!(field.name(), "message" | "error" | "err" | "e" | "cause") {
            self.inspect(&value);
        }
    }
}

impl fmt::Display for SafeFields {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "category={} http_status={:?} matrix_code={}",
            self.category.unwrap_or("unclassified"),
            self.http_status,
            self.matrix_code.unwrap_or("unknown"),
        )
    }
}

struct BoundedText(String);

impl fmt::Write for BoundedText {
    fn write_str(&mut self, value: &str) -> fmt::Result {
        let mut end = value.len().min(4096 - self.0.len());
        while !value.is_char_boundary(end) {
            end -= 1;
        }
        self.0.push_str(&value[..end]);
        if end < value.len() {
            Err(fmt::Error)
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    struct Capture(Arc<Mutex<Vec<String>>>);

    impl<S: Subscriber> tracing_subscriber::Layer<S> for Capture {
        fn on_event(&self, event: &Event<'_>, _: LayerContext<'_, S>) {
            self.0.lock().unwrap().push(sdk_event(event));
        }
    }

    #[test]
    fn sdk_fields_and_dynamic_messages_do_not_leak() {
        let output = Arc::new(Mutex::new(Vec::new()));
        let subscriber = tracing_subscriber::registry().with(Capture(output.clone()));
        tracing::subscriber::with_default(subscriber, || {
            let secret = "PRIVATE_MESSAGE_KEY_TOKEN";
            tracing::error!(
                target: "matrix_sdk::encryption",
                error = ?format!("status_code: 400 M_INVALID_PARAM one-time key already exists {secret}"),
                access_token = secret,
                raw_event = secret,
                "arbitrary message containing {}", secret,
            );
        });
        let output = output.lock().unwrap();
        assert_eq!(output.len(), 1);
        let line = &output[0];
        assert!(line.contains("duplicate_one_time_key"));
        assert!(line.contains("http_status=Some(400)"));
        assert!(line.contains("M_INVALID_PARAM"));
        assert!(!line.contains("PRIVATE_MESSAGE_KEY_TOKEN"));
        assert!(!line.contains("arbitrary message"));
        assert!(!line.contains("raw_event"));
    }

    #[test]
    fn only_sdk_warnings_and_errors_are_enabled() {
        let output = Arc::new(Mutex::new(Vec::new()));
        let subscriber =
            tracing_subscriber::registry().with(Capture(output.clone()).with_filter(sdk_targets()));
        tracing::subscriber::with_default(subscriber, || {
            tracing::warn!(target: "matrix_sdk_crypto::machine", "SDK warning");
            tracing::error!(target: "matrix_sdk_base::client", "SDK error");
            tracing::debug!(target: "matrix_sdk::client", "not enabled");
            tracing::warn!(target: "reqwest", "not enabled");
        });
        assert_eq!(output.lock().unwrap().len(), 2);
    }

    #[test]
    fn unknown_errors_are_redacted_too() {
        let mut fields = SafeFields::default();
        fields.inspect(&"https://example.org/private-token?access_token=SECRET");
        assert_eq!(
            fields.to_string(),
            "category=unclassified http_status=None matrix_code=unknown"
        );
    }

    #[test]
    fn capture_budget_respects_utf8_and_stays_bounded() {
        let mut text = BoundedText(String::new());
        assert!(write!(text, "{}", "鍵".repeat(5000)).is_err());
        assert!(text.0.len() <= 4096);
        assert!(text.0.is_char_boundary(text.0.len()));
    }
}
