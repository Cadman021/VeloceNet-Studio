//! Loads the target list exported by the app (or a bare array) for headless mode.

use std::collections::HashSet;
use std::fs;
use std::path::Path;

use serde_json::Value;

use crate::engine::TargetConfig;
use crate::probe::ProbeProtocol;

const MAX_TARGETS: usize = 500;
const MAX_CONFIG_BYTES: u64 = 16 * 1024 * 1024;
/// Mirrors PingTarget.maxGroupLength in the app so both cap identically.
const MAX_GROUP_CHARS: usize = 40;

pub struct LoadedConfig {
    pub targets: Vec<TargetConfig>,
    pub warnings: Vec<String>,
    pub offline_after: u32,
    pub recover_after: u32,
}

pub fn load(path: &Path) -> Result<LoadedConfig, String> {
    let metadata = fs::metadata(path)
        .map_err(|error| format!("cannot read config {}: {error}", path.display()))?;
    if metadata.len() > MAX_CONFIG_BYTES {
        return Err(format!("config {} is larger than 16 MiB", path.display()));
    }
    let raw = fs::read_to_string(path)
        .map_err(|error| format!("cannot read config {}: {error}", path.display()))?;
    parse(&raw).map_err(|error| format!("{}: {error}", path.display()))
}

pub(crate) fn parse(raw: &str) -> Result<LoadedConfig, String> {
    // Windows editors commonly save JSON as UTF-8 with a BOM; serde rejects
    // the BOM at column 1. Accept it instead of failing the whole daemon.
    let raw = raw.strip_prefix('\u{feff}').unwrap_or(raw);
    let root: Value =
        serde_json::from_str(raw).map_err(|error| format!("invalid JSON: {error}"))?;
    let mut warnings = Vec::new();
    let (entries, settings) = split_root(root, &mut warnings)?;
    let (offline_after, recover_after) = thresholds(settings.as_ref(), &mut warnings);
    if entries.len() > MAX_TARGETS {
        warnings.push(format!(
            "config has {} targets; only the first {MAX_TARGETS} are used",
            entries.len()
        ));
    }

    let mut targets = Vec::new();
    let mut used_ids = HashSet::new();
    let mut next_id = 1u32;
    for (index, entry) in entries.iter().take(MAX_TARGETS).enumerate() {
        match parse_target(entry) {
            Ok(Some(mut target)) => {
                let assigned = if target.id > 0 && used_ids.insert(target.id) {
                    target.id
                } else {
                    if target.id > 0 {
                        warnings.push(format!(
                            "target #{} has duplicate id {}; assigning a new id",
                            index + 1,
                            target.id
                        ));
                    }
                    while used_ids.contains(&next_id) {
                        next_id += 1;
                    }
                    let id = next_id;
                    used_ids.insert(id);
                    id
                };
                target.id = assigned;
                targets.push(target);
            }
            Ok(None) => warnings.push(format!("target #{} is disabled; skipped", index + 1)),
            Err(reason) => warnings.push(format!("target #{} skipped: {reason}", index + 1)),
        }
    }

    Ok(LoadedConfig {
        targets,
        warnings,
        offline_after,
        recover_after,
    })
}

fn split_root(
    root: Value,
    warnings: &mut Vec<String>,
) -> Result<(Vec<Value>, Option<Value>), String> {
    match root {
        Value::Array(entries) => Ok((entries, None)),
        Value::Object(mut map) => {
            if let Some(app) = map.get("app").and_then(Value::as_str) {
                if app != "velocenet-studio" {
                    warnings.push(format!(
                        "config was written by {app}, expected velocenet-studio"
                    ));
                }
            }
            if let Some(version) = map.get("version").and_then(Value::as_u64) {
                if version > 1 {
                    warnings.push(format!(
                        "config schema version {version} is newer than supported version 1"
                    ));
                }
            }
            let entries = match map.remove("targets") {
                Some(Value::Array(entries)) => entries,
                Some(_) => return Err("targets must be an array".to_string()),
                None => return Err("missing targets array".to_string()),
            };
            Ok((entries, map.remove("settings")))
        }
        _ => Err("config must be a JSON object with targets or a bare array".to_string()),
    }
}

fn thresholds(settings: Option<&Value>, warnings: &mut Vec<String>) -> (u32, u32) {
    let mut offline = 3u32;
    let mut recover = 2u32;
    let Some(map) = settings.and_then(Value::as_object) else {
        return (offline, recover);
    };
    for (key, slot) in [
        ("offline_after", &mut offline),
        ("recover_after", &mut recover),
    ] {
        if let Some(value) = map.get(key) {
            match value.as_u64() {
                Some(number) => *slot = number.clamp(1, 20) as u32,
                None => warnings.push(format!(
                    "settings.{key} must be an integer between 1 and 20; using {}",
                    *slot
                )),
            }
        }
    }
    (offline, recover)
}

fn parse_target(entry: &Value) -> Result<Option<TargetConfig>, String> {
    let map = entry.as_object().ok_or("target is not a JSON object")?;
    let enabled = match map.get("is_enabled") {
        Some(Value::Bool(value)) => *value,
        None | Some(Value::Null) => true,
        Some(_) => return Err("is_enabled must be true or false".to_string()),
    };
    if !enabled {
        return Ok(None);
    }

    let raw_host = map.get("host").and_then(Value::as_str).unwrap_or("");
    let host =
        normalize_host(raw_host).ok_or_else(|| format!("invalid host {}", raw_host.trim()))?;
    let port = match map.get("port") {
        None | Some(Value::Null) => 80,
        Some(value) => {
            let port = as_i64(value).ok_or("port must be an integer")?;
            if !(1..=65535).contains(&port) {
                return Err(format!("port {port} is outside 1-65535"));
            }
            port as u16
        }
    };
    let protocol = parse_protocol(map.get("protocol"));
    let http_path = if matches!(protocol, ProbeProtocol::Http | ProbeProtocol::Https) {
        sanitize_http_path(map.get("http_path").and_then(Value::as_str).unwrap_or(""))
    } else {
        String::new()
    };
    let raw_name = map.get("name").and_then(Value::as_str).unwrap_or("").trim();
    let name = truncate_chars(if raw_name.is_empty() { &host } else { raw_name }, 128);
    // The app always writes both keys; hand-written configs may use either.
    let group = sanitize_group(map.get("group").and_then(Value::as_str).unwrap_or(""));
    let muted = map
        .get("is_muted")
        .or_else(|| map.get("muted"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let id = map
        .get("id")
        .and_then(as_i64)
        .filter(|id| *id > 0 && *id <= u32::MAX as i64)
        .unwrap_or(0) as u32;

    Ok(Some(TargetConfig {
        id,
        name,
        host,
        port,
        protocol,
        interval_ms: clamped(map.get("interval_ms"), 1_000, 200, 60_000),
        timeout_ms: clamped(map.get("timeout_ms"), 1_500, 100, 10_000),
        http_path,
        group,
        muted,
    }))
}

fn as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|number| i64::try_from(number).ok()))
        .or_else(|| {
            value
                .as_f64()
                .filter(|number| number.fract() == 0.0)
                .map(|number| number as i64)
        })
        .or_else(|| value.as_str().and_then(|text| text.trim().parse().ok()))
}

fn clamped(value: Option<&Value>, fallback: u64, min: u64, max: u64) -> u64 {
    match value.and_then(as_i64) {
        Some(number) => number.clamp(min as i64, max as i64) as u64,
        None => fallback,
    }
}

fn parse_protocol(value: Option<&Value>) -> ProbeProtocol {
    match value {
        Some(Value::Number(number)) => ProbeProtocol::from_u32(number.as_u64().unwrap_or(0) as u32),
        Some(Value::String(text)) => match text.trim().to_ascii_uppercase().as_str() {
            "TCP" | "1" => ProbeProtocol::Tcp,
            "HTTP" | "2" => ProbeProtocol::Http,
            "HTTPS" | "3" => ProbeProtocol::Https,
            _ => ProbeProtocol::Icmp,
        },
        _ => ProbeProtocol::Icmp,
    }
}

/// Trims, drops control characters and caps at the app's group length.
fn sanitize_group(raw: &str) -> String {
    let trimmed: String = raw.trim().chars().filter(|c| !c.is_control()).collect();
    truncate_chars(&trimmed, MAX_GROUP_CHARS)
}

fn sanitize_http_path(raw: &str) -> String {
    let filtered: String = raw.trim().chars().filter(|c| !c.is_control()).collect();
    let filtered = filtered.trim();
    if filtered.is_empty() {
        return String::new();
    }
    let mut path = if filtered.starts_with("/") {
        filtered.to_string()
    } else {
        format!("/{filtered}")
    };
    if path.chars().count() > 256 {
        path = path.chars().take(256).collect();
    }
    path
}

fn truncate_chars(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

pub(crate) fn normalize_host(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let without_scheme = trimmed
        .strip_prefix("http://")
        .or_else(|| trimmed.strip_prefix("https://"))
        .unwrap_or(trimmed);
    let authority = without_scheme.split("/").next().unwrap_or("");
    let (host, remainder) = if let Some(rest) = authority.strip_prefix("[") {
        let end = rest.find("]")?;
        (&rest[..end], &rest[end + 1..])
    } else {
        (authority, "")
    };
    if !remainder.is_empty() {
        return None;
    }
    let host = host.strip_suffix(".").unwrap_or(host);
    if host.is_empty() || host.len() > 253 {
        return None;
    }
    if host.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    if host.contains(":") {
        return host
            .parse::<std::net::Ipv6Addr>()
            .ok()
            .map(|_| host.to_string());
    }
    let labels: Vec<&str> = host.split(".").collect();
    if labels.len() == 4
        && labels
            .iter()
            .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
    {
        for part in &labels {
            let octet: u16 = part.parse().ok()?;
            if octet > 255 {
                return None;
            }
        }
        return Some(host.to_string());
    }
    if labels.iter().all(|label| valid_label(label)) {
        Some(host.to_string())
    } else {
        None
    }
}

fn valid_label(label: &str) -> bool {
    if label.is_empty() || label.len() > 63 || label.starts_with("-") || label.ends_with("-") {
        return false;
    }
    label
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == 95 || byte == 45)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_json(raw: &str) -> LoadedConfig {
        parse(raw).expect("valid config")
    }

    #[test]
    fn bare_array_applies_defaults() {
        let config = parse_json(r#"[{"host":"1.1.1.1"}]"#);
        assert_eq!(config.targets.len(), 1);
        let target = &config.targets[0];
        assert_eq!(target.id, 1);
        assert_eq!(target.port, 80);
        assert_eq!(target.protocol, ProbeProtocol::Icmp);
        assert_eq!(target.interval_ms, 1_000);
        assert_eq!(target.timeout_ms, 1_500);
        assert_eq!(target.http_path, "");
        assert_eq!(target.name, "1.1.1.1");
    }

    #[test]
    fn utf8_bom_is_tolerated() {
        let config = parse_json("\u{feff}[{\"host\":\"1.1.1.1\"}]");
        assert_eq!(config.targets.len(), 1);
        assert_eq!(config.targets[0].host, "1.1.1.1");
    }

    #[test]
    fn envelope_reads_settings_and_sanitizes_values() {
        let config = parse_json(
            r#"{"app":"velocenet-studio","version":1,
               "settings":{"offline_after":5,"recover_after":4},
               "targets":[{
                 "id":7,"name":"API","host":"https://api.example.com/health",
                 "port":443,"protocol":"HTTPS","http_path":"health",
                 "interval_ms":10,"timeout_ms":99999
               },{"id":8,"host":"bad host"}]}"#,
        );
        assert_eq!(config.offline_after, 5);
        assert_eq!(config.recover_after, 4);
        assert_eq!(config.targets.len(), 1);
        assert_eq!(config.warnings.len(), 1);
        let target = &config.targets[0];
        assert_eq!(target.host, "api.example.com");
        assert_eq!(target.protocol, ProbeProtocol::Https);
        assert_eq!(target.http_path, "/health");
        assert_eq!(target.interval_ms, 200);
        assert_eq!(target.timeout_ms, 10_000);
    }

    #[test]
    fn duplicate_and_missing_ids_get_unique_values() {
        let config = parse_json(
            r#"[{"id":1,"host":"a.example"},{"id":1,"host":"b.example"},{"host":"c.example"}]"#,
        );
        let ids: Vec<u32> = config.targets.iter().map(|target| target.id).collect();
        assert_eq!(ids, vec![1, 2, 3]);
        assert_eq!(config.warnings.len(), 1);
    }

    #[test]
    fn group_and_mute_are_read_for_labels_and_alerts() {
        let config = parse_json(
            r#"[{"host":"a.example","group":"  edge ","is_muted":true},
                {"host":"b.example","muted":true},
                {"host":"c.example","is_muted":"yes"},
                {"host":"d.example","group":""}]"#,
        );
        assert_eq!(config.targets[0].group, "edge");
        assert!(config.targets[0].muted);
        // Hand-written configs may use the short key; anything non-boolean is
        // ignored instead of rejecting the whole target.
        assert!(config.targets[1].muted);
        assert!(!config.targets[2].muted);
        assert_eq!(config.targets[3].group, "");
    }

    #[test]
    fn group_is_capped_and_stripped_of_control_characters() {
        let long = "g".repeat(80);
        let raw = format!(r#"[{{"host":"a.example","group":"{long}\u0007"}}]"#);
        let config = parse_json(&raw);
        assert_eq!(config.targets[0].group.chars().count(), MAX_GROUP_CHARS);
        assert!(!config.targets[0].group.contains('\u{7}'));
    }

    #[test]
    fn disabled_targets_are_skipped() {
        let config = parse_json(r#"[{"host":"a.example","is_enabled":false}]"#);
        assert!(config.targets.is_empty());
        assert_eq!(config.warnings.len(), 1);
    }

    #[test]
    fn host_normalization_matches_app_rules() {
        assert_eq!(
            normalize_host("http://example.com/path"),
            Some("example.com".to_string())
        );
        assert_eq!(
            normalize_host("Example.COM."),
            Some("Example.COM".to_string())
        );
        assert_eq!(
            normalize_host("[2001:db8::1]"),
            Some("2001:db8::1".to_string())
        );
        assert_eq!(normalize_host("1.2.3.999"), None);
        assert_eq!(normalize_host("-bad.example"), None);
        assert_eq!(normalize_host("bad host"), None);
        assert_eq!(normalize_host("https://[2001:db8::1]:443"), None);
    }

    #[test]
    fn missing_targets_array_is_an_error() {
        assert!(parse(r#"{"app":"velocenet-studio"}"#).is_err());
        assert!(parse("[]").is_ok());
        assert!(parse(r#"{"targets":"nope"}"#).is_err());
    }
}
