fn main() {
    // The Runtime pins Marketplace roots with option_env! at compile time.
    // Cargo must invalidate the crate when either root changes; otherwise a
    // staging build can accidentally reuse a production-root object (or vice
    // versa) from the same target directory.
    println!("cargo:rerun-if-env-changed=OCP_MARKETPLACE_TRUST_ROOT_JSON");
    println!("cargo:rerun-if-env-changed=OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON");
}
