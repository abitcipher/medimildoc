use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use ihds::Catalog;
use ihds::http::AppState;
use ihds::learned::Learned;

#[tokio::main]
async fn main() {
    if std::env::args().nth(1).as_deref() == Some("healthcheck") {
        std::process::exit(healthcheck());
    }
    let seed_dir = PathBuf::from(std::env::var("IHDS_SEED_DIR").unwrap_or_else(|_| "seed".into()));
    let addr: SocketAddr = std::env::var("IHDS_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:4100".into())
        .parse()
        .expect("IHDS_ADDR must be host:port");

    let catalog = Catalog::load_dir(&seed_dir).unwrap_or_else(|e| panic!("loading seed: {e}"));
    for d in catalog.datasets.values() {
        println!(
            "ihds: dataset {} — {} entries, version {}",
            d.name,
            d.len(),
            &d.version[..12]
        );
    }
    println!(
        "ihds: seed version {}, listening on {addr}",
        &catalog.version[..12]
    );

    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    // Learned values live on a volume (IHDS_DATA_DIR); without it they are
    // kept in memory only and lost on restart.
    let data_dir = std::env::var("IHDS_DATA_DIR").ok().map(PathBuf::from);
    if data_dir.is_none() {
        println!("ihds: IHDS_DATA_DIR not set, learned values are not persisted");
    }
    let learned = Learned::open(data_dir).unwrap_or_else(|e| panic!("opening learned values: {e}"));
    let state = AppState { catalog, learned };

    axum::serve(listener, ihds::http::router(Arc::new(state)))
        .with_graceful_shutdown(shutdown())
        .await
        .expect("server");
}

/// Ctrl-C locally, SIGTERM from `docker compose stop`.
async fn shutdown() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {},
        _ = term.recv() => {},
    }
}

/// `ihds healthcheck`: exit 0 if `GET /health` on IHDS_ADDR answers 200.
/// Used by the compose healthcheck (the runtime image has no curl).
fn healthcheck() -> i32 {
    use std::io::{Read, Write};
    let port = std::env::var("IHDS_ADDR")
        .ok()
        .and_then(|a| a.rsplit(':').next().map(String::from));
    let addr = format!("127.0.0.1:{}", port.unwrap_or_else(|| "4100".into()));
    let Ok(mut stream) = std::net::TcpStream::connect(&addr) else {
        return 1;
    };
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(3)));
    if stream
        .write_all(b"GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n")
        .is_err()
    {
        return 1;
    }
    let mut response = String::new();
    let _ = stream.read_to_string(&mut response);
    if response.starts_with("HTTP/1.0 200") || response.starts_with("HTTP/1.1 200") {
        0
    } else {
        1
    }
}
