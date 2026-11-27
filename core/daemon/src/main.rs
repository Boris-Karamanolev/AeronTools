use aeron_platform::AeronCore;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .init();

    let port = std::env::var("AERON_DAEMON_PORT")
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(47620);

    let core = AeronCore::new();
    if let Err(err) = aeron_daemon::serve(core, port).await {
        eprintln!("aeron-daemon exited with error: {err}");
        std::process::exit(1);
    }
}
