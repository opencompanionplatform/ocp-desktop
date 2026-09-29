use ocp_package_loader::marketplace_trust::verify;
use std::{env, fs};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 || args.len() > 4 {
        return Err("usage: check_marketplace_bundle <marketplace-root.json> <marketplace-bundle.json> [unix-time]".into());
    }
    let root = fs::read_to_string(&args[1])?;
    let bundle = fs::read_to_string(&args[2])?;
    let now = if args.len() == 4 {
        args[3].parse::<i64>()?
    } else {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs()
            .try_into()?
    };
    let verified = verify(&bundle, &root, now)
        .map_err(|code| format!("marketplace trust rejected: {code}"))?;
    println!(
        "marketplace trust verified: root={} sequence={} active_publishers={}",
        verified.root_key_id, verified.sequence, verified.publisher_count
    );
    Ok(())
}
