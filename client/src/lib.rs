use serde_json::{json, Value};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedAd {
    pub title: String,
    pub prompt_line: String,
}

pub trait HttpClient {
    fn post(&self, url: &str, body: Option<&str>) -> Result<String, String>;
}

#[derive(Debug, Clone)]
pub struct RefreshConfig {
    pub cache_dir: PathBuf,
    pub api_base: String,
    pub cwd: PathBuf,
    pub event_input: String,
    pub display_ttl_secs: u64,
    pub min_dwell_secs: u64,
    pub now: SystemTime,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefreshOutcome {
    SkippedNoRender,
    SkippedDwell,
    NoPublisher,
    NoAd,
    Served { category: String, ad_text: String },
}

pub fn strip_terminal_controls(input: &str) -> String {
    input.chars().filter(|ch| !ch.is_control()).collect()
}

pub fn truncate_chars(input: &str, max_chars: usize) -> String {
    if max_chars == 0 {
        return String::new();
    }
    let len = input.chars().count();
    if len <= max_chars {
        return input.to_string();
    }
    if max_chars <= 3 {
        return ".".repeat(max_chars);
    }
    let keep = max_chars - 3;
    let mut out: String = input.chars().take(keep).collect();
    out.push_str("...");
    out
}

pub fn render_ad(
    balance_display: &str,
    ad_text: Option<&str>,
    max_title: usize,
    max_line: usize,
) -> RenderedAd {
    let balance = normalize_space(&strip_terminal_controls(balance_display));
    let balance = if balance.is_empty() {
        "⊕ $0.00".to_string()
    } else {
        balance
    };
    let ad = ad_text
        .map(strip_terminal_controls)
        .map(|s| normalize_space(&s))
        .filter(|s| !s.is_empty());

    let title = match ad.as_deref() {
        Some(ad) => format!("{balance} · {ad}"),
        None => balance.clone(),
    };
    let prompt_line = match ad.as_deref() {
        Some(ad) => format!("{balance}  {ad}"),
        None => balance,
    };

    RenderedAd {
        title: truncate_chars(&title, max_title),
        prompt_line: truncate_chars(&prompt_line, max_line),
    }
}

pub fn mark_render_seen(cache_dir: &Path, now: SystemTime) -> std::io::Result<()> {
    fs::create_dir_all(cache_dir)?;
    fs::write(
        cache_dir.join("last_render_seen"),
        unix_secs(now).to_string(),
    )
}

pub fn render_is_fresh(cache_dir: &Path, now: SystemTime, ttl_secs: u64) -> bool {
    heartbeat_is_fresh(cache_dir, "last_render_seen", now, ttl_secs)
}

pub fn should_attempt_serve(
    cache_dir: &Path,
    now: SystemTime,
    render_ttl_secs: u64,
    min_dwell_secs: u64,
) -> bool {
    if !render_is_fresh(cache_dir, now, render_ttl_secs) {
        return false;
    }

    let last_serve = fs::read_to_string(cache_dir.join("last_serve"))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0);
    let now_secs = unix_secs(now);
    now_secs.saturating_sub(last_serve) >= min_dwell_secs
}

pub fn refresh_once<C: HttpClient>(config: &RefreshConfig, client: &C) -> RefreshOutcome {
    if fs::create_dir_all(&config.cache_dir).is_err() {
        return RefreshOutcome::NoAd;
    }

    if !render_is_fresh(&config.cache_dir, config.now, config.display_ttl_secs) {
        let _ = fs::write(config.cache_dir.join("last_skipped"), "no_render");
        return RefreshOutcome::SkippedNoRender;
    }

    if !should_attempt_serve(
        &config.cache_dir,
        config.now,
        config.display_ttl_secs,
        config.min_dwell_secs,
    ) {
        let _ = fs::write(config.cache_dir.join("last_skipped"), "dwell");
        return RefreshOutcome::SkippedDwell;
    }

    let (category, source) = classify(config);
    let mut publisher_id = read_publisher_id(&config.cache_dir);
    if publisher_id.is_none() {
        let ref_code = read_ref_code(&config.cache_dir);
        match register(config, client, ref_code.as_deref()) {
            Ok(body) => {
                let _ = fs::write(config.cache_dir.join("identity.json"), &body);
                let _ = set_private_file(&config.cache_dir.join("identity.json"));
                publisher_id = publisher_id_from_json(&body);
                if publisher_id.is_some() {
                    let _ = fs::remove_file(config.cache_dir.join("ref"));
                }
            }
            Err(_) => return RefreshOutcome::NoPublisher,
        }
    }
    let Some(mut publisher_id) = publisher_id else {
        return RefreshOutcome::NoPublisher;
    };

    let now_secs = unix_secs(config.now);
    let _ = fs::write(config.cache_dir.join("last_serve"), now_secs.to_string());
    let mut response = serve(config, client, &publisher_id, &category, now_secs, "");

    if response
        .as_deref()
        .unwrap_or_default()
        .contains("unknown_publisher")
    {
        match register(config, client, None) {
            Ok(body) => {
                let _ = fs::write(config.cache_dir.join("identity.json"), &body);
                let _ = set_private_file(&config.cache_dir.join("identity.json"));
                if let Some(id) = publisher_id_from_json(&body) {
                    publisher_id = id;
                    response = serve(config, client, &publisher_id, &category, now_secs, "-r");
                }
            }
            Err(_) => return RefreshOutcome::NoPublisher,
        }
    }

    let Some(body) = response else {
        return RefreshOutcome::NoAd;
    };
    let value: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    let ad_text = value
        .get("text")
        .and_then(Value::as_str)
        .map(strip_terminal_controls)
        .map(|s| normalize_space(&s))
        .unwrap_or_default();

    write_balance_files(&config.cache_dir, value.get("balance_usd"));

    if ad_text.is_empty() {
        let _ = fs::write(config.cache_dir.join("current_ad.txt"), "");
        let _ = fs::write(config.cache_dir.join("current_click.txt"), "");
        return RefreshOutcome::NoAd;
    }

    let balance_display = fs::read_to_string(config.cache_dir.join("balance_display"))
        .unwrap_or_else(|_| "⊕ $0.00".to_string());
    let rendered = render_ad(&balance_display, Some(&ad_text), 80, 160);

    let _ = fs::write(config.cache_dir.join("current_ad.txt"), &ad_text);
    let click_url = click_url_from_response(&value).unwrap_or_default();
    let _ = fs::write(config.cache_dir.join("current_click.txt"), click_url);
    let _ = fs::write(config.cache_dir.join("category.txt"), &category);
    let _ = fs::write(config.cache_dir.join("source.txt"), &source);
    let _ = fs::write(config.cache_dir.join("title.txt"), rendered.title);
    let _ = fs::write(
        config.cache_dir.join("prompt_line.txt"),
        rendered.prompt_line,
    );
    let _ = fs::write(
        config.cache_dir.join("terminal.txt"),
        format!(
            "{}\n{}\n",
            fs::read_to_string(config.cache_dir.join("title.txt")).unwrap_or_default(),
            fs::read_to_string(config.cache_dir.join("prompt_line.txt")).unwrap_or_default()
        ),
    );
    let _ = append_impression(&config.cache_dir, now_secs, &source, &category, &ad_text);

    RefreshOutcome::Served { category, ad_text }
}

pub fn click_url_from_response(value: &Value) -> Option<String> {
    value
        .get("click_url")
        .and_then(Value::as_str)
        .filter(|url| !url.trim().is_empty())
        .map(|url| url.trim().to_string())
        .or_else(|| {
            value
                .get("impression_id")
                .and_then(Value::as_str)
                .filter(|id| !id.trim().is_empty())
                .map(|id| format!("/v1/click/{}", strip_terminal_controls(id.trim())))
        })
}

pub fn resolve_open_url(input: &str, api_base: &str) -> Option<String> {
    let input = input.trim();
    if input.starts_with("https://") || input.starts_with("http://") {
        return Some(strip_terminal_controls(input));
    }
    if input.starts_with('/') && !input.starts_with("//") {
        return Some(format!(
            "{}{}",
            api_base.trim_end_matches('/'),
            strip_terminal_controls(input)
        ));
    }
    None
}

pub fn sanitize_ref_code(input: &str) -> String {
    let mut out = String::new();
    for ch in input.chars().flat_map(char::to_lowercase) {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
            out.push(ch);
            if out.len() >= 32 {
                break;
            }
        }
    }
    out
}

pub fn ref_code_from_values(env_ref: Option<&str>, file_ref: Option<&str>) -> Option<String> {
    env_ref
        .filter(|s| !s.trim().is_empty())
        .or(file_ref)
        .map(sanitize_ref_code)
        .filter(|s| !s.is_empty())
}

pub fn read_ref_code(cache_dir: &Path) -> Option<String> {
    let env_ref = env::var("ADTENTION_REF").ok();
    let file_ref = fs::read_to_string(cache_dir.join("ref")).ok();
    ref_code_from_values(env_ref.as_deref(), file_ref.as_deref())
}

pub fn classify_terminal_command(command: &str) -> Option<&'static str> {
    let command = command.trim();
    if command.is_empty() || command.starts_with('#') {
        return None;
    }

    let lower = command.to_lowercase();
    let first = lower
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .trim_start_matches("command ")
        .trim_start_matches("exec ");

    if matches!(
        first,
        "npm" | "pnpm" | "yarn" | "bun" | "vite" | "next" | "npx"
    ) || lower.contains("react")
        || lower.contains("tsx")
        || lower.contains("jsx")
    {
        return Some("web");
    }
    if matches!(
        first,
        "docker" | "docker-compose" | "kubectl" | "helm" | "terraform" | "tofu" | "nginx"
    ) {
        return Some("devops");
    }
    if matches!(first, "cargo" | "rustc" | "go" | "make") {
        return Some("systems");
    }
    if matches!(
        first,
        "python" | "python3" | "pytest" | "pip" | "uv" | "jupyter"
    ) || lower.contains("pandas")
        || lower.contains("dataset")
    {
        return Some("data");
    }
    if matches!(first, "forge" | "cast" | "hardhat" | "anvil") || lower.contains("solidity") {
        return Some("web3");
    }
    None
}

fn classify(config: &RefreshConfig) -> (String, String) {
    if let Some(command) = command_from_event(&config.event_input) {
        if let Some(category) = classify_terminal_command(&command) {
            return (category.to_string(), "command".to_string());
        }
    }
    (classify_folder(&config.cwd), "folder".to_string())
}

fn command_from_event(input: &str) -> Option<String> {
    let value: Value = serde_json::from_str(input).ok()?;
    let source = value
        .get("source")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if source != "terminal-enter" {
        return None;
    }
    value
        .get("command")
        .and_then(Value::as_str)
        .filter(|command| !command.trim().is_empty())
        .map(str::to_string)
}

fn classify_folder(cwd: &Path) -> String {
    let has = |name: &str| cwd.join(name).exists();
    if has("foundry.toml") || glob_ext(cwd, "sol") || glob_prefix(cwd, "hardhat.config.") {
        return "web3".to_string();
    }
    if has("Dockerfile") || glob_ext(cwd, "tf") {
        return "devops".to_string();
    }
    if has("package.json") {
        return "web".to_string();
    }
    if has("requirements.txt") || glob_ext(cwd, "py") {
        return "data".to_string();
    }
    if has("Cargo.toml") || has("go.mod") {
        return "systems".to_string();
    }
    "general".to_string()
}

fn register<C: HttpClient>(
    config: &RefreshConfig,
    client: &C,
    ref_code: Option<&str>,
) -> Result<String, String> {
    let body = ref_code.map(|ref_code| json!({ "ref": ref_code }).to_string());
    client.post(
        &format!("{}/v1/register", config.api_base.trim_end_matches('/')),
        body.as_deref(),
    )
}

fn serve<C: HttpClient>(
    config: &RefreshConfig,
    client: &C,
    publisher_id: &str,
    category: &str,
    now_secs: u64,
    nonce_suffix: &str,
) -> Option<String> {
    let nonce = format!("{now_secs}-terminal{nonce_suffix}");
    let body = json!({
        "publisher_id": publisher_id,
        "category": category,
        "nonce": nonce
    })
    .to_string();
    client
        .post(
            &format!("{}/v1/serve", config.api_base.trim_end_matches('/')),
            Some(&body),
        )
        .ok()
}

fn read_publisher_id(cache_dir: &Path) -> Option<String> {
    let body = fs::read_to_string(cache_dir.join("identity.json")).ok()?;
    publisher_id_from_json(&body)
}

fn publisher_id_from_json(body: &str) -> Option<String> {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            v.get("publisher_id")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .filter(|s| !s.is_empty())
}

fn write_balance_files(cache_dir: &Path, balance: Option<&Value>) {
    let Some(balance) = balance else {
        return;
    };
    let amount = match balance {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    };
    if let Some(amount) = amount {
        let _ = fs::write(cache_dir.join("balance"), amount.to_string());
        let _ = fs::write(cache_dir.join("balance_display"), format!("⊕ ${amount:.2}"));
    }
}

fn append_impression(
    cache_dir: &Path,
    now_secs: u64,
    source: &str,
    category: &str,
    ad_text: &str,
) -> std::io::Result<()> {
    use std::io::Write;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(cache_dir.join("impressions.log"))?;
    writeln!(file, "{now_secs}\t{source}\t{category}\t{ad_text}")
}

fn heartbeat_is_fresh(cache_dir: &Path, file_name: &str, now: SystemTime, ttl_secs: u64) -> bool {
    let path = cache_dir.join(file_name);
    if let Ok(contents) = fs::read_to_string(&path) {
        if let Ok(secs) = contents.trim().parse::<u64>() {
            let now_secs = unix_secs(now);
            return now_secs.saturating_sub(secs) <= ttl_secs;
        }
    }

    let modified = match fs::metadata(&path).and_then(|m| m.modified()) {
        Ok(modified) => modified,
        Err(_) => return false,
    };
    match now.duration_since(modified) {
        Ok(age) => age.as_secs() <= ttl_secs,
        Err(_) => true,
    }
}

fn glob_ext(cwd: &Path, ext: &str) -> bool {
    fs::read_dir(cwd)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| entry.path().extension().and_then(|s| s.to_str()) == Some(ext))
}

fn glob_prefix(cwd: &Path, prefix: &str) -> bool {
    fs::read_dir(cwd)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| {
            entry
                .file_name()
                .to_str()
                .map(|s| s.starts_with(prefix))
                .unwrap_or(false)
        })
}

fn normalize_space(input: &str) -> String {
    let mut out = String::new();
    let mut last_was_space = false;
    for ch in input.chars() {
        if ch.is_whitespace() {
            if !last_was_space {
                out.push(' ');
                last_was_space = true;
            }
        } else {
            out.push(ch);
            last_was_space = false;
        }
    }
    out.trim().to_string()
}

fn unix_secs(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(unix)]
fn set_private_file(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(0o600);
    fs::set_permissions(path, permissions)
}

#[cfg(not(unix))]
fn set_private_file(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;
    use std::time::{Duration, UNIX_EPOCH};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    struct FakeHttp {
        posts: Mutex<Vec<(String, Option<String>)>>,
    }

    impl FakeHttp {
        fn new() -> Self {
            Self {
                posts: Mutex::new(Vec::new()),
            }
        }

        fn bodies(&self) -> Vec<String> {
            self.posts
                .lock()
                .unwrap()
                .iter()
                .filter_map(|(_, body)| body.clone())
                .collect()
        }
    }

    impl HttpClient for FakeHttp {
        fn post(&self, url: &str, body: Option<&str>) -> Result<String, String> {
            self.posts
                .lock()
                .unwrap()
                .push((url.to_string(), body.map(str::to_string)));
            if url.ends_with("/v1/register") {
                return Ok(r#"{"publisher_id":"pub_test"}"#.to_string());
            }
            Ok(
                r#"{"text":"Terminal sponsor","balance_usd":4.20,"click_url":"https://example.com/click"}"#
                    .to_string(),
            )
        }
    }

    fn temp_dir() -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "adtention-terminal-test-{}-{}",
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn config(cache_dir: PathBuf, cwd: PathBuf, event_input: &str) -> RefreshConfig {
        RefreshConfig {
            cache_dir,
            api_base: "https://api.example.test".to_string(),
            cwd,
            event_input: event_input.to_string(),
            display_ttl_secs: 120,
            min_dwell_secs: 15,
            now: SystemTime::now(),
        }
    }

    #[test]
    fn refresh_skips_without_recent_render() {
        let tmp = temp_dir();
        let http = FakeHttp::new();
        let outcome = refresh_once(&config(tmp.clone(), tmp, ""), &http);

        assert_eq!(outcome, RefreshOutcome::SkippedNoRender);
        assert!(http.bodies().is_empty());
    }

    #[test]
    fn refresh_skips_inside_dwell_window() {
        let tmp = temp_dir();
        let now = SystemTime::now();
        mark_render_seen(&tmp, now).unwrap();
        fs::write(
            tmp.join("last_serve"),
            now.duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
                .to_string(),
        )
        .unwrap();

        let http = FakeHttp::new();
        let outcome = refresh_once(&config(tmp.clone(), tmp, ""), &http);

        assert_eq!(outcome, RefreshOutcome::SkippedDwell);
        assert!(http.bodies().is_empty());
    }

    #[test]
    fn refresh_serves_without_leaking_command_or_cwd() {
        let tmp = temp_dir();
        let cwd = tmp.join("secret-repo-name");
        fs::create_dir_all(&cwd).unwrap();
        fs::write(cwd.join("package.json"), "{}").unwrap();
        mark_render_seen(&tmp, SystemTime::now()).unwrap();
        fs::write(tmp.join("last_serve"), "0").unwrap();
        let event = json!({
            "source": "terminal-enter",
            "shell": "zsh",
            "command": "npm test -- --secret-token",
            "cwd": cwd
        });

        let http = FakeHttp::new();
        let outcome = refresh_once(&config(tmp.clone(), tmp.clone(), &event.to_string()), &http);

        assert_eq!(
            outcome,
            RefreshOutcome::Served {
                category: "web".to_string(),
                ad_text: "Terminal sponsor".to_string()
            }
        );
        let serve_body = http
            .bodies()
            .into_iter()
            .find(|body| body.contains("publisher_id"))
            .expect("serve call body");
        assert!(serve_body.contains("\"category\":\"web\""));
        assert!(!serve_body.contains("npm test"));
        assert!(!serve_body.contains("secret-token"));
        assert!(!serve_body.contains("secret-repo-name"));
        assert_eq!(
            fs::read_to_string(tmp.join("current_ad.txt")).unwrap(),
            "Terminal sponsor"
        );
    }

    #[test]
    fn command_classifier_covers_common_developer_commands() {
        let cases = [
            ("npm test", Some("web")),
            ("pnpm dev", Some("web")),
            ("vite build", Some("web")),
            ("docker build .", Some("devops")),
            ("kubectl get pods", Some("devops")),
            ("terraform plan", Some("devops")),
            ("cargo test", Some("systems")),
            ("go test ./...", Some("systems")),
            ("python train.py", Some("data")),
            ("pytest", Some("data")),
            ("forge test", Some("web3")),
            ("hardhat test", Some("web3")),
            ("unknown-tool run", None),
        ];

        for (command, expected) in cases {
            assert_eq!(classify_terminal_command(command), expected, "{command}");
        }
    }

    #[test]
    fn render_ad_strips_terminal_control_sequences() {
        let rendered = render_ad(
            "⊕ $1.23",
            Some("Neon\u{1b}]0;pwned\u{7}\nPostgres"),
            80,
            120,
        );

        assert_eq!(rendered.title, "⊕ $1.23 · Neon]0;pwnedPostgres");
        assert_eq!(rendered.prompt_line, "⊕ $1.23  Neon]0;pwnedPostgres");
        assert!(!rendered.title.contains('\u{1b}'));
        assert!(!rendered.title.contains('\u{7}'));
        assert!(!rendered.title.contains('\n'));
    }

    #[test]
    fn click_urls_resolve_safely() {
        assert_eq!(
            resolve_open_url("https://example.com", "https://api.adtention.ai").as_deref(),
            Some("https://example.com")
        );
        assert_eq!(
            resolve_open_url("/v1/click/imp_123", "https://api.adtention.ai/").as_deref(),
            Some("https://api.adtention.ai/v1/click/imp_123")
        );
        assert_eq!(
            resolve_open_url("javascript:alert(1)", "https://api.adtention.ai"),
            None
        );
        assert_eq!(
            resolve_open_url("//example.com", "https://api.adtention.ai"),
            None
        );
    }

    #[test]
    fn old_render_heartbeat_is_not_fresh() {
        let tmp = temp_dir();
        let old = UNIX_EPOCH + Duration::from_secs(100);
        let now = UNIX_EPOCH + Duration::from_secs(300);
        mark_render_seen(&tmp, old).unwrap();

        assert!(!render_is_fresh(&tmp, now, 120));
    }
}
