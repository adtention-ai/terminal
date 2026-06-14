use adtention_terminal::{
    mark_render_seen, refresh_once, render_ad, resolve_open_url, HttpClient, RefreshConfig,
};
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct CurlHttp;

impl HttpClient for CurlHttp {
    fn post(&self, url: &str, body: Option<&str>) -> Result<String, String> {
        let mut cmd = Command::new("curl");
        cmd.args(["-s", "-m", "5", "-X", "POST", url]);
        if let Some(body) = body {
            cmd.args(["-H", "content-type: application/json", "-d", body]);
        }
        let output = cmd.output().map_err(|err| err.to_string())?;
        if !output.status.success() {
            return Err(format!("curl exited with {}", output.status));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }
}

fn main() {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        print_usage_and_exit();
    };

    let code = match command.as_str() {
        "setup" => setup().map(|_| 0).unwrap_or(0),
        "refresh" => {
            let cwd = args
                .next()
                .map(PathBuf::from)
                .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
            refresh(cwd).map(|_| 0).unwrap_or(0)
        }
        "render" => render().map(|_| 0).unwrap_or(0),
        "mark-display" | "mark-render" => mark_render_seen(&cache_dir(), SystemTime::now())
            .map(|_| 0)
            .unwrap_or(0),
        "title-daemon" => {
            let interval = parse_env_u64("ADTENTION_TITLE_INTERVAL", 15).max(5);
            title_daemon(interval).map(|_| 0).unwrap_or(0)
        }
        "open" => {
            let target = args.next();
            open_sponsor(target).map(|_| 0).unwrap_or(1)
        }
        "doctor" => doctor().map(|_| 0).unwrap_or(1),
        _ => {
            eprintln!("unknown command: {command}");
            2
        }
    };
    std::process::exit(code);
}

fn setup() -> io::Result<()> {
    let cache = cache_dir();
    fs::create_dir_all(&cache)?;
    write_if_missing(cache.join("balance_display"), "⊕ $0.00")?;
    write_if_missing(cache.join("title.txt"), "⊕ $0.00")?;
    write_if_missing(cache.join("prompt_line.txt"), "⊕ $0.00")?;
    write_if_missing(cache.join("terminal.txt"), "⊕ $0.00\n⊕ $0.00\n")?;
    Ok(())
}

fn refresh(cwd: PathBuf) -> io::Result<()> {
    let mut event_input = String::new();
    let _ = io::stdin().read_to_string(&mut event_input);
    let config = RefreshConfig {
        cache_dir: cache_dir(),
        api_base: env::var("ADTENTION_API")
            .unwrap_or_else(|_| "https://api.adtention.ai".to_string()),
        cwd,
        event_input,
        display_ttl_secs: parse_env_u64("ADTENTION_DISPLAY_TTL", 120),
        min_dwell_secs: parse_env_u64("ADTENTION_MIN_DWELL", 15),
        now: SystemTime::now(),
    };
    let _ = refresh_once(&config, &CurlHttp);
    Ok(())
}

fn render() -> io::Result<()> {
    let cache = cache_dir();
    let balance =
        fs::read_to_string(cache.join("balance_display")).unwrap_or_else(|_| "⊕ $0.00".to_string());
    let ad = fs::read_to_string(cache.join("current_ad.txt")).ok();
    let max_width = parse_env_usize("ADTENTION_MAX_WIDTH", columns().unwrap_or(120));
    let rendered = render_ad(&balance, ad.as_deref(), 80, max_width);
    fs::write(cache.join("title.txt"), &rendered.title).ok();
    fs::write(cache.join("prompt_line.txt"), &rendered.prompt_line).ok();
    fs::write(
        cache.join("terminal.txt"),
        format!("{}\n{}\n", rendered.title, rendered.prompt_line),
    )
    .ok();
    mark_render_seen(&cache, SystemTime::now()).ok();
    println!("{}", rendered.prompt_line);
    Ok(())
}

fn title_daemon(interval_secs: u64) -> io::Result<()> {
    let cache = cache_dir();
    loop {
        let title = fs::read_to_string(cache.join("title.txt"))
            .or_else(|_| fs::read_to_string(cache.join("balance_display")))
            .unwrap_or_else(|_| "⊕ $0.00".to_string());
        let title = title.trim();
        if !title.is_empty() {
            print!("\x1b]0;{title}\x07");
            let _ = io::stdout().flush();
        }
        thread::sleep(Duration::from_secs(interval_secs));
    }
}

fn open_sponsor(target: Option<String>) -> io::Result<()> {
    let raw_url = match target {
        Some(url) => url,
        None => fs::read_to_string(cache_dir().join("current_click.txt")).unwrap_or_default(),
    };
    let api = env::var("ADTENTION_API").unwrap_or_else(|_| "https://api.adtention.ai".to_string());
    let Some(url) = resolve_open_url(&raw_url, &api) else {
        if raw_url.trim().is_empty() {
            println!("adtention: no sponsor to open yet. Run a command, then try again.");
        } else {
            println!("adtention: refusing to open an unsupported URL.");
        }
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid URL"));
    };
    open_url(&url)?;
    println!("adtention: opened the sponsor in your browser.");
    Ok(())
}

fn doctor() -> io::Result<()> {
    let cache = cache_dir();
    println!("adtention doctor");
    println!("cache: {}", cache.display());
    println!("client: {}", current_exe_display());
    println!(
        "last_render_seen: {}",
        age_display(&cache.join("last_render_seen"))
    );
    println!("last_serve: {}", age_display(&cache.join("last_serve")));
    if let Ok(reason) = fs::read_to_string(cache.join("last_skipped")) {
        println!("last_skipped: {}", reason.trim());
    }
    Ok(())
}

fn open_url(url: &str) -> io::Result<()> {
    if let Some(program) = env::var_os("ADTENTION_OPEN_COMMAND") {
        return Command::new(program).arg(url).status().map(|_| ());
    }
    #[cfg(target_os = "macos")]
    {
        return Command::new("open").arg(url).status().map(|_| ());
    }
    #[cfg(target_os = "windows")]
    {
        return Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", url])
            .status()
            .map(|_| ());
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        return Command::new("xdg-open").arg(url).status().map(|_| ());
    }
    #[allow(unreachable_code)]
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "unsupported platform",
    ))
}

fn cache_dir() -> PathBuf {
    env::var_os("ADTENTION_CACHE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = env::var_os("HOME")
                .or_else(|| env::var_os("USERPROFILE"))
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."));
            home.join(".adtention").join("terminal")
        })
}

fn write_if_missing(path: PathBuf, contents: &str) -> io::Result<()> {
    if !path.exists() {
        fs::write(path, contents)?;
    }
    Ok(())
}

fn parse_env_u64(name: &str, default: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

fn parse_env_usize(name: &str, default: usize) -> usize {
    env::var(name)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

fn columns() -> Option<usize> {
    env::var("COLUMNS").ok().and_then(|s| s.parse().ok())
}

fn current_exe_display() -> String {
    env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn age_display(path: &Path) -> String {
    let Ok(contents) = fs::read_to_string(path) else {
        return "missing".to_string();
    };
    let Ok(secs) = contents.trim().parse::<u64>() else {
        return "present".to_string();
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}s ago", now.saturating_sub(secs))
}

fn print_usage_and_exit() -> ! {
    eprintln!(
        "usage: adtention-terminal <setup|refresh|render|mark-render|title-daemon|open|doctor>"
    );
    std::process::exit(2);
}
