// Entry point. Sets up the crypto provider, parses CLI args, initialises
// logging, then hands off to cli::run.
use clap::Parser;

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let cli = datieve::cli::Cli::parse();

    // Set log level from CLI arg (overrides env)
    std::env::set_var("RUST_LOG", format!("datieve={}", cli.log));

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(format!("datieve={}", cli.log).parse().unwrap()),
        )
        .init();

    if let Err(e) = datieve::cli::run(cli).await {
        tracing::error!("{}", e);
        std::process::exit(1);
    }
}
