//! I7 Voice V1 slice 3: the OS-voice `tts` synthesizer.
//!
//! [`synthesize_wav`] renders text to a WAV byte buffer using the operating
//! system's built-in voice. On Windows it drives **System.Speech.Synthesis**
//! (present on every Windows, no install) via a short PowerShell invocation
//! that writes to a temp `.wav` file — **headless**: it renders to a file, not
//! the speakers, so it works with no audio device and in test runners. The
//! spoken text is passed through an **environment variable**, never
//! interpolated into the command string, so no text can inject PowerShell.
//!
//! Deliberately **no WinRT/COM/`unsafe`** for V1 — a subprocess is simple,
//! robust, and easy to verify; an in-process WinRT `SpeechSynthesizer` is a
//! later performance optimization behind this same safe function. The router's
//! `tts` adapter (V1 slice 3b) calls this, `put`s the bytes into the audio
//! store, and returns an `audioRef`.
//!
//! [`wav_duration_ms`] is a platform-independent WAV parser (used to fill
//! `audioRef.duration_ms`), unit-tested on its own so the format logic is
//! verified without needing a real voice.

#![forbid(unsafe_code)]

use std::fmt;

#[cfg(windows)]
use std::time::{Duration, Instant};

/// System.Speech is an external Windows component. Some hosts can leave its
/// synthesis call pending indefinitely when no usable voice is registered, so
/// the Runtime must never wait forever on the fallback path.
#[cfg(windows)]
const WINDOWS_SYNTHESIS_TIMEOUT: Duration = Duration::from_secs(20);

/// Why an OS-voice synthesis attempt failed.
#[derive(Debug)]
pub enum TtsError {
    /// No OS-voice backend on this platform (only Windows is wired for V1).
    Unsupported,
    /// The OS has no enabled voice matching the requested language/profile.
    NoMatchingVoice {
        language: String,
        gender: String,
        age: String,
    },
    /// The synthesizer subprocess failed to start or exited non-zero.
    SynthesisFailed(String),
    /// The rendered file could not be read back.
    Io(String),
}

impl fmt::Display for TtsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => write!(f, "OS-voice TTS is not implemented on this platform"),
            Self::NoMatchingVoice {
                language,
                gender,
                age,
            } => write!(
                f,
                "no installed OS voice matches language={language}, gender={gender}, age={age}"
            ),
            Self::SynthesisFailed(m) => write!(f, "OS-voice synthesis failed: {m}"),
            Self::Io(m) => write!(f, "reading the rendered audio failed: {m}"),
        }
    }
}

impl std::error::Error for TtsError {}

/// Renders `text` to WAV bytes using the OS voice. See the module docs for the
/// (headless, injection-safe) Windows mechanism. Returns `Unsupported` off
/// Windows for V1.
pub fn synthesize_wav(text: &str) -> Result<Vec<u8>, TtsError> {
    synthesize_wav_with_preference(text, &VoicePreference::default())
}

/// Provider-neutral selection hints for an installed OS voice. Empty values
/// mean "no restriction"; text is still passed independently and safely.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VoicePreference {
    pub language: String,
    pub gender: String,
    pub age: String,
    pub voice_name: String,
}

/// Renders text with an installed voice that matches the requested language
/// and profile. It never feeds Thai text to an arbitrary English voice.
pub fn synthesize_wav_with_preference(
    text: &str,
    preference: &VoicePreference,
) -> Result<Vec<u8>, TtsError> {
    #[cfg(windows)]
    {
        synthesize_windows(text, preference)
    }
    #[cfg(not(windows))]
    {
        let _ = (text, preference);
        Err(TtsError::Unsupported)
    }
}

/// Checks whether Windows has an enabled voice matching the language/profile.
/// This returns metadata availability only and never speaks or exposes the
/// installed voice name.
pub fn has_matching_voice(preference: &VoicePreference) -> Result<bool, TtsError> {
    #[cfg(windows)]
    {
        use std::process::Command;
        let script = "\
            Add-Type -AssemblyName System.Speech; \
            $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; \
            $voices = @($s.GetInstalledVoices() | Where-Object { $_.Enabled }); \
            $candidates = @($voices | Where-Object { $_.VoiceInfo.Culture.Name -like ($env:OCP_TTS_LANGUAGE + '*') }); \
            if ($env:OCP_TTS_GENDER -and $env:OCP_TTS_GENDER -ne 'neutral') { $candidates = @($candidates | Where-Object { $_.VoiceInfo.Gender.ToString() -ieq $env:OCP_TTS_GENDER }) }; \
            if ($env:OCP_TTS_AGE -ieq 'child') { $candidates = @($candidates | Where-Object { $_.VoiceInfo.Age.ToString() -in @('Child','Teen') }) }; \
            if ($env:OCP_TTS_AGE -ieq 'adult') { $candidates = @($candidates | Where-Object { $_.VoiceInfo.Age.ToString() -in @('Adult','Senior') }) }; \
            $s.Dispose(); \
            if ($candidates.Count -gt 0) { exit 0 } else { exit 42 }";
        let status = Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .env("OCP_TTS_LANGUAGE", &preference.language)
            .env("OCP_TTS_GENDER", &preference.gender)
            .env("OCP_TTS_AGE", &preference.age)
            .status()
            .map_err(|error| {
                TtsError::SynthesisFailed(format!("could not query voices: {error}"))
            })?;
        Ok(status.success())
    }
    #[cfg(not(windows))]
    {
        let _ = preference;
        Err(TtsError::Unsupported)
    }
}

#[cfg(windows)]
fn synthesize_windows(text: &str, preference: &VoicePreference) -> Result<Vec<u8>, TtsError> {
    use std::process::Command;

    let out_path = std::env::temp_dir().join(format!("ocp-tts-{}.wav", uuid::Uuid::now_v7()));

    // Text and output path are passed via environment variables and read back
    // inside the script (`$env:...`), never interpolated into the command —
    // so arbitrary spoken text cannot inject PowerShell.
    let script = "\
        Add-Type -AssemblyName System.Speech; \
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; \
        $voices = @($s.GetInstalledVoices() | Where-Object { $_.Enabled }); \
        $selected = $null; \
        if ($env:OCP_TTS_VOICE) { $selected = $voices | Where-Object { $_.VoiceInfo.Name -ieq $env:OCP_TTS_VOICE } | Select-Object -First 1 }; \
        if (-not $selected -and $env:OCP_TTS_LANGUAGE) { \
            $candidates = @($voices | Where-Object { $_.VoiceInfo.Culture.Name -like ($env:OCP_TTS_LANGUAGE + '*') }); \
            if ($env:OCP_TTS_GENDER -and $env:OCP_TTS_GENDER -ne 'neutral') { $candidates = @($candidates | Where-Object { $_.VoiceInfo.Gender.ToString() -ieq $env:OCP_TTS_GENDER }) }; \
            if ($env:OCP_TTS_AGE -ieq 'child') { $candidates = @($candidates | Where-Object { $_.VoiceInfo.Age.ToString() -in @('Child','Teen') }) }; \
            if ($env:OCP_TTS_AGE -ieq 'adult') { $candidates = @($candidates | Where-Object { $_.VoiceInfo.Age.ToString() -in @('Adult','Senior') }) }; \
            $selected = $candidates | Select-Object -First 1; \
        }; \
        if (($env:OCP_TTS_VOICE -or $env:OCP_TTS_LANGUAGE) -and -not $selected) { $s.Dispose(); exit 42 }; \
        if ($selected) { $s.SelectVoice($selected.VoiceInfo.Name) }; \
        $s.SetOutputToWaveFile($env:OCP_TTS_OUT); \
        $s.Speak($env:OCP_TTS_TEXT); \
        $s.Dispose()";

    let mut child = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .env("OCP_TTS_TEXT", text)
        .env("OCP_TTS_OUT", &out_path)
        .env("OCP_TTS_LANGUAGE", &preference.language)
        .env("OCP_TTS_GENDER", &preference.gender)
        .env("OCP_TTS_AGE", &preference.age)
        .env("OCP_TTS_VOICE", &preference.voice_name)
        .spawn()
        .map_err(|e| TtsError::SynthesisFailed(format!("could not run powershell: {e}")))?;

    let status = match wait_for_child(&mut child, WINDOWS_SYNTHESIS_TIMEOUT)
        .map_err(|e| TtsError::SynthesisFailed(format!("could not wait for powershell: {e}")))?
    {
        Some(status) => status,
        None => {
            let _ = std::fs::remove_file(&out_path);
            return Err(TtsError::SynthesisFailed(format!(
                "powershell synthesis timed out after {} seconds",
                WINDOWS_SYNTHESIS_TIMEOUT.as_secs()
            )));
        }
    };

    if !status.success() {
        let _ = std::fs::remove_file(&out_path);
        if status.code() == Some(42) {
            return Err(TtsError::NoMatchingVoice {
                language: preference.language.clone(),
                gender: preference.gender.clone(),
                age: preference.age.clone(),
            });
        }
        return Err(TtsError::SynthesisFailed(format!(
            "powershell exited with {status}"
        )));
    }

    let bytes = std::fs::read(&out_path).map_err(|e| TtsError::Io(e.to_string()))?;
    let _ = std::fs::remove_file(&out_path); // best-effort cleanup
    Ok(bytes)
}

/// Wait for a child to exit without allowing an unresponsive OS voice provider
/// to keep a Runtime request alive forever. `None` means the timeout expired;
/// in that case the child has been terminated and reaped.
#[cfg(windows)]
fn wait_for_child(
    child: &mut std::process::Child,
    timeout: Duration,
) -> std::io::Result<Option<std::process::ExitStatus>> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Some(status));
        }
        if Instant::now() >= deadline {
            child.kill()?;
            let _ = child.wait();
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Duration of a canonical PCM WAV in milliseconds, from its `fmt ` byte-rate
/// and `data` chunk length. `None` if `wav` isn't a RIFF/WAVE file or lacks
/// those chunks. Platform-independent — the router uses it to fill
/// `audioRef.duration_ms` for subtitle timing.
#[must_use]
pub fn wav_duration_ms(wav: &[u8]) -> Option<u32> {
    if wav.len() < 12 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return None;
    }
    let mut pos = 12;
    let mut byte_rate: Option<u32> = None;
    let mut data_len: Option<u32> = None;
    while pos + 8 <= wav.len() {
        let id = &wav[pos..pos + 4];
        let size =
            u32::from_le_bytes([wav[pos + 4], wav[pos + 5], wav[pos + 6], wav[pos + 7]]) as usize;
        let data_start = pos + 8;
        if id == b"fmt " && data_start + 16 <= wav.len() {
            // fmt layout: audioFormat(2) numChannels(2) sampleRate(4) byteRate(4) ...
            byte_rate = Some(u32::from_le_bytes([
                wav[data_start + 8],
                wav[data_start + 9],
                wav[data_start + 10],
                wav[data_start + 11],
            ]));
        } else if id == b"data" {
            data_len = Some(size as u32);
        }
        // RIFF chunks are word-aligned: an odd size carries one pad byte.
        pos = data_start + size + (size & 1);
    }
    match (byte_rate, data_len) {
        (Some(br), Some(dl)) if br > 0 => {
            Some(u32::try_from(u64::from(dl) * 1000 / u64::from(br)).unwrap_or(u32::MAX))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a minimal canonical PCM WAV header + `data` chunk of `data_len`
    /// bytes, with the given `byte_rate`, for the duration parser tests.
    fn craft_wav(byte_rate: u32, data_len: u32) -> Vec<u8> {
        let mut w = Vec::new();
        w.extend_from_slice(b"RIFF");
        w.extend_from_slice(&(36 + data_len).to_le_bytes()); // riff chunk size (not checked by parser)
        w.extend_from_slice(b"WAVE");
        w.extend_from_slice(b"fmt ");
        w.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
        w.extend_from_slice(&1u16.to_le_bytes()); // PCM
        w.extend_from_slice(&1u16.to_le_bytes()); // mono
        w.extend_from_slice(&16_000u32.to_le_bytes()); // sample rate
        w.extend_from_slice(&byte_rate.to_le_bytes()); // byte rate
        w.extend_from_slice(&2u16.to_le_bytes()); // block align
        w.extend_from_slice(&16u16.to_le_bytes()); // bits/sample
        w.extend_from_slice(b"data");
        w.extend_from_slice(&data_len.to_le_bytes());
        w.extend(std::iter::repeat_n(0u8, data_len as usize));
        w
    }

    #[test]
    fn wav_duration_is_data_len_over_byte_rate() {
        // 32000 bytes/sec (16kHz mono 16-bit), 32000 bytes of data = 1.000 s.
        assert_eq!(wav_duration_ms(&craft_wav(32_000, 32_000)), Some(1000));
        // half a second of data.
        assert_eq!(wav_duration_ms(&craft_wav(32_000, 16_000)), Some(500));
    }

    #[test]
    fn wav_duration_rejects_non_wav_and_zero_byte_rate() {
        assert_eq!(wav_duration_ms(b"not a wav file at all"), None);
        assert_eq!(wav_duration_ms(&[]), None);
        assert_eq!(
            wav_duration_ms(&craft_wav(0, 1000)),
            None,
            "a zero byte-rate can't yield a duration"
        );
    }

    #[cfg(windows)]
    #[test]
    fn unresponsive_windows_voice_subprocess_is_terminated_at_the_deadline() {
        let mut child = std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Start-Sleep -Seconds 5",
            ])
            .spawn()
            .expect("test powershell must start");
        let status = wait_for_child(&mut child, Duration::from_millis(25))
            .expect("waiting for child must succeed");
        assert!(
            status.is_none(),
            "the helper must return timeout, not wait for sleep"
        );
    }

    /// The real OS-voice path. Windows-only (System.Speech), and headless
    /// (renders to a temp file, no audio device needed), so it runs in a plain
    /// test runner. Verifies a real, valid WAV came back — not that it *sounds*
    /// right (a human listen is a separate check).
    ///
    /// This is opt-in because System.Speech can block on a Windows host
    /// without a usable voice provider. Run explicitly with:
    /// `cargo test -p ocp-os-tts --lib -- --ignored`
    #[cfg(windows)]
    #[test]
    #[ignore = "requires an opt-in Windows System.Speech voice host"]
    fn synthesize_wav_produces_a_valid_wav_on_windows() {
        let wav = synthesize_wav("Open Companion Platform voice online.")
            .expect("OS voice must synthesize");
        assert!(
            wav.len() > 44,
            "a real clip is larger than just a WAV header"
        );
        assert_eq!(&wav[0..4], b"RIFF", "output must be a RIFF container");
        assert_eq!(&wav[8..12], b"WAVE", "output must be a WAVE file");
        assert!(
            wav_duration_ms(&wav).is_some(),
            "the rendered WAV must have a parseable duration"
        );
    }
}
