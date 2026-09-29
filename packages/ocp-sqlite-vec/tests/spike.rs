//! sqlite-vec slice-2 **spike** (ADR-0010 vector search): before `ocp-memory`'s
//! `SqliteStore` depends on sqlite-vec, prove the single biggest unknown in
//! isolation — that the sqlite-vec `cc` native build compiles, that
//! [`register`](ocp_sqlite_vec::register) makes its functions available to a
//! rusqlite connection, and that a real cosine-distance KNN ranks correctly —
//! on *this* toolchain (Windows ARM64) and alongside *this* SQLite build
//! (SQLCipher, via `bundled-sqlcipher-vendored-openssl`). Same spirit as the
//! WASI capability spike that gated PLUGIN_API §7.
//!
//! Only after this is green does the real backend integration follow (manual
//! `vec_distance_cosine` brute-force over a scope-filtered candidate set —
//! ADR-0010: "adequate for personal-scale memory" — with the `vec0` ANN index
//! as a later optimization).

use rusqlite::{params, Connection};

#[test]
fn sqlite_vec_builds_registers_and_ranks_by_cosine_distance() {
    ocp_sqlite_vec::register();
    let db = Connection::open_in_memory().expect("connection must open");

    // 1. sqlite-vec is actually loaded into this connection.
    let version: String = db
        .query_row("SELECT vec_version()", [], |r| r.get(0))
        .expect("vec_version() must resolve");
    assert!(
        !version.is_empty(),
        "vec_version() must return the loaded sqlite-vec version string"
    );

    // 2. store 3-dimensional float32 vectors as blobs in an ordinary table,
    //    with the recommended dimension CHECK constraint.
    db.execute_batch("CREATE TABLE items(id TEXT PRIMARY KEY, embedding BLOB CHECK(vec_length(embedding) == 3));")
        .expect("create table with a vec_length CHECK must succeed");
    db.execute(
        "INSERT INTO items VALUES (?1, vec_f32(?2))",
        params!["identical", "[1, 0, 0]"],
    )
    .unwrap();
    db.execute(
        "INSERT INTO items VALUES (?1, vec_f32(?2))",
        params!["close", "[0.9, 0.1, 0]"],
    )
    .unwrap();
    db.execute(
        "INSERT INTO items VALUES (?1, vec_f32(?2))",
        params!["orthogonal", "[0, 0, 1]"],
    )
    .unwrap();

    // 3. brute-force cosine KNN via the scalar function: smaller distance = nearer.
    let mut stmt = db
        .prepare("SELECT id FROM items ORDER BY vec_distance_cosine(embedding, vec_f32(?1)) ASC")
        .expect("prepare cosine-distance query");
    let ranked: Vec<String> = stmt
        .query_map(params!["[1, 0, 0]"], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();

    assert_eq!(
        ranked,
        vec![
            "identical".to_owned(),
            "close".to_owned(),
            "orthogonal".to_owned()
        ],
        "cosine distance must order identical (0) < close < orthogonal (1)"
    );
}

/// The real backend keys its connection with SQLCipher (`PRAGMA key`). Prove
/// the sqlite-vec functions still work with keying engaged, so wiring it into
/// the encrypted `SqliteStore` won't hit a surprise.
#[test]
fn sqlite_vec_functions_work_on_a_keyed_sqlcipher_connection() {
    ocp_sqlite_vec::register();
    let db = Connection::open_in_memory().expect("connection must open");
    db.execute_batch(
        "PRAGMA key = \"x'00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'\";",
    )
    .expect("keying the connection must succeed");

    let version: String = db
        .query_row("SELECT vec_version()", [], |r| r.get(0))
        .expect("vec_version() on a keyed connection");
    assert!(!version.is_empty());

    let self_distance: f64 = db
        .query_row(
            "SELECT vec_distance_cosine(vec_f32('[1, 0, 0]'), vec_f32('[1, 0, 0]'))",
            [],
            |r| r.get(0),
        )
        .expect("cosine distance must compute on a keyed connection");
    assert!(
        self_distance.abs() < 1e-6,
        "cosine distance of a vector to itself is 0"
    );
}
