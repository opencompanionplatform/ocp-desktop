//! I7 Voice: the kernel-owned temp audio store behind the `audioRef` shared
//! type (EVENT_CATALOG.md; VOICE.md §3.1; gaps 1+2 Approved 2026-07-22).
//!
//! Audio cannot ride the ≤1 MiB JSON envelope / IPC frame, and base64 blobs on
//! the bus would break envelope-size hygiene. So audio bytes live here, and
//! everything on the bus carries only an [`AudioRef`] (id + metadata). A
//! **producer** — a `tts` router adapter synthesizing speech, or the mic
//! capture path (V2) — calls [`AudioStore::put`] and gets back an `AudioRef`
//! it can put in an event. A **consumer** — the runtime about to play a
//! `speech-requested` clip, or an `stt` adapter about to transcribe captured
//! mic audio — calls [`AudioStore::take`], which hands over the bytes and
//! **removes them** (single-consumer). Refs a consumer never resolves are
//! swept by [`AudioStore::evict_expired`], so audio never accumulates.
//!
//! This crate is only the store + the reference type; wiring it to real TTS
//! synthesis (V1), mic capture and STT (V2), the runtime's playback, and the
//! IPC ref-resolution framing are their own later slices.

#![forbid(unsafe_code)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// Audio container format for an [`AudioRef`] — matches EVENT_CATALOG.md's
/// `audioRef.format` enum. V1 uses `Wav` (uncompressed PCM, what OS/local TTS
/// emits — no encode/decode needed); `Opus` is reserved for a later slice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AudioFormat {
    Wav,
    Opus,
}

/// The `audioRef` shared type (EVENT_CATALOG.md): a **reference** to audio
/// bytes held in the [`AudioStore`], never the bytes themselves. Carries just
/// enough metadata to route, schedule, and verify the clip without moving it:
/// its store `id`, container `format`, `duration_ms` (so a scheduler/subtitle
/// timer knows how long playback will take before resolving the bytes), and
/// the `sha256` of the bytes for integrity across the transport boundary.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioRef {
    pub id: Uuid,
    pub format: AudioFormat,
    pub duration_ms: u32,
    pub sha256: String,
}

struct StoredAudio {
    bytes: Vec<u8>,
    audio_ref: AudioRef,
    stored_at: Instant,
}

/// The kernel-owned temp audio store. Thread-safe (`&self` methods behind an
/// internal `Mutex`) so a single instance can be shared — the kernel owns it,
/// a `tts` adapter holds a producer handle, the runtime-facing IPC layer holds
/// a consumer handle.
#[derive(Default)]
pub struct AudioStore {
    entries: Mutex<HashMap<Uuid, StoredAudio>>,
    /// When set (`with_dir`), every clip is also mirrored to
    /// `<dir>/<id>.wav` so a **co-located** consumer (the desktop runtime,
    /// I7 V1 slice 4b) can read the file directly — the chosen file-backed
    /// transport (no binary-IPC path). `None` = in-memory only (tests, the
    /// router's own unit runs).
    dir: Option<PathBuf>,
}

impl AudioStore {
    /// In-memory-only store: `peek`/`take` work, but nothing is written to
    /// disk (no co-located file consumer).
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// File-backed store: each `put` also writes `<dir>/<id>.wav` for a
    /// co-located consumer to read (I7 V1 slice 4b). Creates `dir` if absent;
    /// the runtime must point `OCP_AUDIO_DIR` at the same path (same
    /// `<id>.wav` filename convention).
    pub fn with_dir(dir: impl Into<PathBuf>) -> std::io::Result<Self> {
        let dir = dir.into();
        std::fs::create_dir_all(&dir)?;
        Ok(Self {
            entries: Mutex::new(HashMap::new()),
            dir: Some(dir),
        })
    }

    /// The on-disk path a clip is mirrored to, or `None` for an in-memory
    /// store. The runtime derives the same path from `OCP_AUDIO_DIR` + the id.
    #[must_use]
    pub fn clip_path(&self, id: Uuid) -> Option<PathBuf> {
        self.dir.as_ref().map(|d| d.join(format!("{id}.wav")))
    }

    /// Stores `bytes` and returns the [`AudioRef`] that stands in for them on
    /// the bus. Computes the `sha256` and a fresh time-ordered `id`;
    /// `duration_ms` is supplied by the producer (it knows the sample rate /
    /// synthesis length — this store is format-agnostic and does not decode).
    pub fn put(&self, bytes: Vec<u8>, format: AudioFormat, duration_ms: u32) -> AudioRef {
        let id = Uuid::now_v7();
        let sha256 = hex_lower(&Sha256::digest(&bytes));
        let audio_ref = AudioRef {
            id,
            format,
            duration_ms,
            sha256,
        };
        // Mirror to disk for a co-located consumer before moving `bytes` into
        // the map (the runtime reads this file directly, slice 4b). A file
        // write only fails on real disk trouble; the in-memory copy is still
        // authoritative for `peek`/`take`, so a failed mirror degrades to
        // tts-unavailable at the runtime rather than losing the clip here.
        if let Some(path) = self.clip_path(id) {
            let _ = std::fs::write(&path, &bytes);
        }
        self.entries
            .lock()
            .expect("audio store mutex poisoned")
            .insert(
                id,
                StoredAudio {
                    bytes,
                    audio_ref: audio_ref.clone(),
                    stored_at: Instant::now(),
                },
            );
        audio_ref
    }

    /// Reads a clip's [`AudioRef`] metadata **without consuming it** — the
    /// kernel needs `format`/`durationMs`/`sha256` to build the
    /// `speech-requested` event (and a scheduler needs `durationMs` to time
    /// subtitles) *before* the runtime later resolves the bytes with
    /// [`take`](Self::take). `None` for an unknown/evicted id.
    pub fn peek(&self, id: Uuid) -> Option<AudioRef> {
        self.entries
            .lock()
            .expect("audio store mutex poisoned")
            .get(&id)
            .map(|s| s.audio_ref.clone())
    }

    /// Resolves a ref **once**: returns the bytes and removes them from the
    /// store (single-consumer — a second `take` of the same id returns
    /// `None`). `None` too for an unknown or already-evicted id.
    pub fn take(&self, id: Uuid) -> Option<Vec<u8>> {
        let removed = self
            .entries
            .lock()
            .expect("audio store mutex poisoned")
            .remove(&id)
            .map(|s| s.bytes);
        if removed.is_some() {
            if let Some(path) = self.clip_path(id) {
                let _ = std::fs::remove_file(path); // single-consumer: the mirrored file goes too
            }
        }
        removed
    }

    /// Sweeps every clip older than `max_age` (a ref no consumer resolved in
    /// time). The kernel calls this periodically so unresolved audio never
    /// accumulates; `max_age` is the store's retention window.
    pub fn evict_expired(&self, max_age: Duration) {
        let mut entries = self.entries.lock().expect("audio store mutex poisoned");
        let expired: Vec<Uuid> = entries
            .iter()
            .filter(|(_, s)| s.stored_at.elapsed() >= max_age)
            .map(|(id, _)| *id)
            .collect();
        for id in expired {
            entries.remove(&id);
            if let Some(path) = self.clip_path(id) {
                let _ = std::fs::remove_file(path); // sweep the mirrored file too
            }
        }
    }

    /// Number of clips currently held (test/observability aid).
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries
            .lock()
            .expect("audio store mutex poisoned")
            .len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Lowercase-hex of a byte slice (for `audioRef.sha256`). Small and local so
/// this crate takes no hex dependency.
fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(char::from_digit(u32::from(b >> 4), 16).expect("nibble"));
        s.push(char::from_digit(u32::from(b & 0x0f), 16).expect("nibble"));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_then_take_round_trips_the_bytes_and_metadata() {
        let store = AudioStore::new();
        let bytes = b"fake wav audio bytes".to_vec();
        let audio = store.put(bytes.clone(), AudioFormat::Wav, 1234);

        assert_eq!(audio.format, AudioFormat::Wav);
        assert_eq!(audio.duration_ms, 1234);
        assert_eq!(audio.sha256.len(), 64, "sha256 hex is 32 bytes = 64 chars");
        assert_eq!(store.len(), 1);

        let taken = store.take(audio.id).expect("a fresh ref resolves once");
        assert_eq!(taken, bytes, "take returns exactly the stored bytes");
        assert!(store.is_empty(), "take removes the clip");
    }

    #[test]
    fn take_is_single_consumer() {
        let store = AudioStore::new();
        let audio = store.put(b"once".to_vec(), AudioFormat::Wav, 10);
        assert!(store.take(audio.id).is_some(), "first take succeeds");
        assert!(
            store.take(audio.id).is_none(),
            "a second take of the same ref returns None (single-consumer)"
        );
    }

    #[test]
    fn take_of_an_unknown_id_is_none() {
        let store = AudioStore::new();
        assert!(store.take(Uuid::now_v7()).is_none());
    }

    #[test]
    fn in_memory_store_mirrors_no_files() {
        let store = AudioStore::new();
        let audio = store.put(b"bytes".to_vec(), AudioFormat::Wav, 1);
        assert!(
            store.clip_path(audio.id).is_none(),
            "an in-memory store has no on-disk path"
        );
    }

    #[test]
    fn file_backed_store_writes_the_clip_on_put_and_removes_it_on_take() {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = AudioStore::with_dir(dir.path()).expect("file-backed store opens");
        let bytes = b"RIFF....WAVE fake clip".to_vec();

        let audio = store.put(bytes.clone(), AudioFormat::Wav, 500);
        let path = store
            .clip_path(audio.id)
            .expect("file-backed store has a path");
        assert_eq!(
            path,
            dir.path().join(format!("{}.wav", audio.id)),
            "id-based filename convention"
        );
        assert_eq!(
            std::fs::read(&path).expect("clip file exists on disk"),
            bytes,
            "the co-located runtime reads these bytes"
        );

        assert!(store.take(audio.id).is_some());
        assert!(
            !path.exists(),
            "single-consumer: taking the clip removes its mirrored file too"
        );
    }

    #[test]
    fn evict_expired_sweeps_mirrored_files() {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = AudioStore::with_dir(dir.path()).expect("file-backed store opens");
        let audio = store.put(b"clip".to_vec(), AudioFormat::Wav, 1);
        let path = store.clip_path(audio.id).unwrap();
        assert!(path.exists());

        std::thread::sleep(Duration::from_millis(20));
        store.evict_expired(Duration::from_millis(1));
        assert!(store.is_empty(), "the entry is evicted");
        assert!(!path.exists(), "and its mirrored file is swept from disk");
    }

    #[test]
    fn peek_reads_metadata_without_consuming() {
        let store = AudioStore::new();
        let audio = store.put(b"clip".to_vec(), AudioFormat::Wav, 777);
        let peeked = store.peek(audio.id).expect("peek finds a stored ref");
        assert_eq!(peeked.duration_ms, 777);
        assert_eq!(peeked.sha256, audio.sha256);
        assert_eq!(store.len(), 1, "peek must not consume the clip");
        assert!(
            store.take(audio.id).is_some(),
            "the bytes are still resolvable after a peek"
        );
        assert!(
            store.peek(audio.id).is_none(),
            "once taken, peek finds nothing"
        );
    }

    #[test]
    fn sha256_is_stable_for_the_same_bytes_and_differs_for_different_bytes() {
        let store = AudioStore::new();
        let a = store.put(b"identical".to_vec(), AudioFormat::Wav, 1);
        let b = store.put(b"identical".to_vec(), AudioFormat::Wav, 1);
        let c = store.put(b"different".to_vec(), AudioFormat::Wav, 1);
        assert_eq!(a.sha256, b.sha256, "same bytes -> same integrity hash");
        assert_ne!(a.sha256, c.sha256, "different bytes -> different hash");
        // A known-answer check pins the algorithm (sha256("") is well-known).
        let empty = store.put(Vec::new(), AudioFormat::Wav, 0);
        assert_eq!(
            empty.sha256,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn evict_expired_sweeps_old_refs_but_keeps_recent_ones() {
        let store = AudioStore::new();
        let audio = store.put(b"clip".to_vec(), AudioFormat::Wav, 5);
        assert_eq!(store.len(), 1);

        // A generous retention window keeps a just-stored clip.
        store.evict_expired(Duration::from_secs(3600));
        assert_eq!(store.len(), 1, "a fresh clip is well within a 1h window");

        // Let it age past a tiny window, then sweep.
        std::thread::sleep(Duration::from_millis(20));
        store.evict_expired(Duration::from_millis(1));
        assert!(store.is_empty(), "a clip older than the window is evicted");
        assert!(
            store.take(audio.id).is_none(),
            "and is no longer resolvable"
        );
    }
}
