use ocp_package_loader::{load, marketplace_trust::verify};
use std::{env, fs};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 || args.len() > 5 {
        return Err("usage: check_marketplace_package <marketplace-root.json> <marketplace-bundle.json> <package.ocp> [unix-time]".into());
    }
    let root = fs::read_to_string(&args[1])?;
    let bundle = fs::read_to_string(&args[2])?;
    let bytes = fs::read(&args[3])?;
    let now = if args.len() == 5 {
        args[4].parse::<i64>()?
    } else {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs()
            .try_into()?
    };
    let verified = verify(&bundle, &root, now)
        .map_err(|code| format!("marketplace trust rejected: {code}"))?;
    let package =
        load(&bytes, &verified.store).map_err(|error| format!("package rejected: {error:?}"))?;
    println!(
        "marketplace package verified: id={} version={} publisher={} key={} sequence={}",
        package.manifest.id,
        package.manifest.version,
        package.manifest.publisher.id,
        package.manifest.signature.key_id,
        verified.sequence,
    );
    Ok(())
}
