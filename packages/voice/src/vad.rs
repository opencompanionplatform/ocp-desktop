//! Lightweight client-side voice activity detection for Voice Realtime V2.
//!
//! The detector is deliberately dependency-free and allocation-free per audio
//! frame. It consumes signed 16-bit mono PCM and applies RMS energy hysteresis
//! plus start/end frame debouncing. The Runtime can therefore decide speech
//! boundaries locally before opening/ending a cloud ASR turn, without sending
//! continuous room audio or adding a heavyweight ML model to the render loop.

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VadConfig {
    /// RMS amplitude (0.0..=1.0) required while idle to count as voiced.
    pub start_threshold: f32,
    /// Lower RMS amplitude used while already speaking to avoid chattering.
    pub continue_threshold: f32,
    /// Consecutive voiced frames required before `SpeechStarted`.
    pub start_frames: u16,
    /// Consecutive quiet frames required before `SpeechEnded`.
    pub end_frames: u16,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            start_threshold: 0.018,
            continue_threshold: 0.010,
            start_frames: 3,
            end_frames: 12,
        }
    }
}

impl VadConfig {
    #[must_use]
    pub fn sanitized(self) -> Self {
        let start_threshold = self.start_threshold.clamp(0.000_1, 1.0);
        let continue_threshold = self.continue_threshold.clamp(0.000_1, start_threshold);
        Self {
            start_threshold,
            continue_threshold,
            start_frames: self.start_frames.max(1),
            end_frames: self.end_frames.max(1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VadState {
    Silence,
    Speech,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VadTransition {
    SpeechStarted,
    SpeechEnded,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VadDecision {
    pub state: VadState,
    pub transition: Option<VadTransition>,
    pub rms: f32,
    pub peak: f32,
}

#[derive(Debug, Clone)]
pub struct VoiceActivityDetector {
    config: VadConfig,
    state: VadState,
    voiced_run: u16,
    quiet_run: u16,
}

impl VoiceActivityDetector {
    #[must_use]
    pub fn new(config: VadConfig) -> Self {
        Self {
            config: config.sanitized(),
            state: VadState::Silence,
            voiced_run: 0,
            quiet_run: 0,
        }
    }

    #[must_use]
    pub fn state(&self) -> VadState {
        self.state
    }

    pub fn reset(&mut self) {
        self.state = VadState::Silence;
        self.voiced_run = 0;
        self.quiet_run = 0;
    }

    /// Update thresholds/debounce without resetting the current speech state.
    /// This lets Runtime raise the start threshold while its own TTS is audible
    /// without losing an already-active user utterance during barge-in.
    pub fn set_config(&mut self, config: VadConfig) {
        self.config = config.sanitized();
    }

    #[must_use]
    pub fn process_pcm16(&mut self, samples: &[i16]) -> VadDecision {
        let (rms, peak) = pcm16_energy(samples);
        self.process_energy(rms, peak)
    }

    /// Process signed PCM16 little-endian bytes without allocating an i16
    /// staging buffer. Runtime microphone capture uses this path at 20 ms
    /// cadence, so the render process avoids ~50 short-lived allocations/sec.
    #[must_use]
    pub fn process_pcm16_le_bytes(&mut self, pcm_le: &[u8]) -> VadDecision {
        let (rms, peak) = pcm16_le_energy(pcm_le);
        self.process_energy(rms, peak)
    }

    fn process_energy(&mut self, rms: f32, peak: f32) -> VadDecision {
        let mut transition = None;

        match self.state {
            VadState::Silence => {
                if rms >= self.config.start_threshold {
                    self.voiced_run = self.voiced_run.saturating_add(1);
                } else {
                    self.voiced_run = 0;
                }
                self.quiet_run = 0;
                if self.voiced_run >= self.config.start_frames {
                    self.state = VadState::Speech;
                    self.voiced_run = 0;
                    transition = Some(VadTransition::SpeechStarted);
                }
            }
            VadState::Speech => {
                if rms >= self.config.continue_threshold {
                    self.quiet_run = 0;
                } else {
                    self.quiet_run = self.quiet_run.saturating_add(1);
                }
                self.voiced_run = 0;
                if self.quiet_run >= self.config.end_frames {
                    self.state = VadState::Silence;
                    self.quiet_run = 0;
                    transition = Some(VadTransition::SpeechEnded);
                }
            }
        }

        VadDecision {
            state: self.state,
            transition,
            rms,
            peak,
        }
    }
}

#[must_use]
pub fn pcm16_energy(samples: &[i16]) -> (f32, f32) {
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let mut sum_squares = 0.0_f64;
    let mut peak = 0.0_f32;
    for &sample in samples {
        let normalized = f32::from(sample) / 32768.0;
        peak = peak.max(normalized.abs());
        let value = f64::from(normalized);
        sum_squares += value * value;
    }
    let rms = (sum_squares / samples.len() as f64).sqrt() as f32;
    (rms, peak)
}

#[must_use]
pub fn pcm16_le_energy(pcm_le: &[u8]) -> (f32, f32) {
    if pcm_le.len() < 2 {
        return (0.0, 0.0);
    }
    let mut sum_squares = 0.0_f64;
    let mut peak = 0.0_f32;
    let mut count = 0usize;
    for bytes in pcm_le.chunks_exact(2) {
        let sample = i16::from_le_bytes([bytes[0], bytes[1]]);
        let normalized = f32::from(sample) / 32768.0;
        peak = peak.max(normalized.abs());
        let value = f64::from(normalized);
        sum_squares += value * value;
        count += 1;
    }
    if count == 0 {
        return (0.0, 0.0);
    }
    ((sum_squares / count as f64).sqrt() as f32, peak)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(amplitude: i16) -> Vec<i16> {
        let mut samples = Vec::with_capacity(640);
        for _ in 0..160 {
            samples.extend_from_slice(&[amplitude, -amplitude, amplitude, -amplitude]);
        }
        samples
    }

    #[test]
    fn silence_does_not_start_a_turn() {
        let mut vad = VoiceActivityDetector::new(VadConfig::default());
        for _ in 0..30 {
            let decision = vad.process_pcm16(&frame(100));
            assert_eq!(decision.state, VadState::Silence);
            assert_eq!(decision.transition, None);
        }
    }

    #[test]
    fn speech_requires_debounced_voiced_frames() {
        let mut vad = VoiceActivityDetector::new(VadConfig {
            start_threshold: 0.02,
            continue_threshold: 0.01,
            start_frames: 3,
            end_frames: 4,
        });
        assert_eq!(vad.process_pcm16(&frame(1200)).transition, None);
        assert_eq!(vad.process_pcm16(&frame(1200)).transition, None);
        let decision = vad.process_pcm16(&frame(1200));
        assert_eq!(decision.transition, Some(VadTransition::SpeechStarted));
        assert_eq!(decision.state, VadState::Speech);
    }

    #[test]
    fn short_transient_is_rejected() {
        let mut vad = VoiceActivityDetector::new(VadConfig::default());
        let _ = vad.process_pcm16(&frame(4000));
        let _ = vad.process_pcm16(&frame(4000));
        let decision = vad.process_pcm16(&frame(0));
        assert_eq!(decision.state, VadState::Silence);
        assert_eq!(decision.transition, None);
    }

    #[test]
    fn hysteresis_keeps_soft_speech_active() {
        let mut vad = VoiceActivityDetector::new(VadConfig {
            start_threshold: 0.03,
            continue_threshold: 0.008,
            start_frames: 1,
            end_frames: 3,
        });
        assert_eq!(
            vad.process_pcm16(&frame(3000)).transition,
            Some(VadTransition::SpeechStarted)
        );
        for _ in 0..10 {
            let decision = vad.process_pcm16(&frame(500));
            assert_eq!(decision.state, VadState::Speech);
            assert_eq!(decision.transition, None);
        }
    }

    #[test]
    fn speech_end_uses_quiet_hangover() {
        let mut vad = VoiceActivityDetector::new(VadConfig {
            start_threshold: 0.02,
            continue_threshold: 0.01,
            start_frames: 1,
            end_frames: 3,
        });
        let _ = vad.process_pcm16(&frame(2000));
        assert_eq!(vad.process_pcm16(&frame(0)).transition, None);
        assert_eq!(vad.process_pcm16(&frame(0)).transition, None);
        let decision = vad.process_pcm16(&frame(0));
        assert_eq!(decision.transition, Some(VadTransition::SpeechEnded));
        assert_eq!(decision.state, VadState::Silence);
    }

    #[test]
    fn echo_guard_threshold_rejects_leakage_but_allows_near_field_speech() {
        let mut vad = VoiceActivityDetector::new(VadConfig {
            start_threshold: 0.055,
            continue_threshold: 0.025,
            start_frames: 4,
            end_frames: 12,
        });
        for _ in 0..8 {
            let decision = vad.process_pcm16(&frame(1200));
            assert_eq!(decision.state, VadState::Silence);
            assert_eq!(decision.transition, None);
        }
        for _ in 0..3 {
            let decision = vad.process_pcm16(&frame(4000));
            assert_eq!(decision.transition, None);
        }
        assert_eq!(
            vad.process_pcm16(&frame(4000)).transition,
            Some(VadTransition::SpeechStarted)
        );
    }

    #[test]
    fn config_can_raise_threshold_without_resetting_active_state() {
        let mut vad = VoiceActivityDetector::new(VadConfig {
            start_threshold: 0.02,
            continue_threshold: 0.01,
            start_frames: 1,
            end_frames: 3,
        });
        assert_eq!(
            vad.process_pcm16(&frame(3000)).transition,
            Some(VadTransition::SpeechStarted)
        );
        vad.set_config(VadConfig {
            start_threshold: 0.06,
            continue_threshold: 0.025,
            start_frames: 4,
            end_frames: 3,
        });
        assert_eq!(vad.state(), VadState::Speech);
        let decision = vad.process_pcm16(&frame(2000));
        assert_eq!(decision.state, VadState::Speech);
    }

    #[test]
    fn energy_is_normalized_and_bounded() {
        let (rms, peak) = pcm16_energy(&[i16::MIN, i16::MAX, 0, 0]);
        assert!(rms > 0.0 && rms <= 1.0);
        assert!(peak > 0.99 && peak <= 1.0);
        assert_eq!(pcm16_energy(&[]), (0.0, 0.0));
    }

    #[test]
    fn little_endian_byte_path_matches_sample_path_without_staging_allocation() {
        let samples = [i16::MIN, -1200, 0, 1200, i16::MAX];
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for sample in samples {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        let sample_energy = pcm16_energy(&samples);
        let byte_energy = pcm16_le_energy(&bytes);
        assert!((sample_energy.0 - byte_energy.0).abs() < 0.000_001);
        assert!((sample_energy.1 - byte_energy.1).abs() < 0.000_001);

        let mut sample_vad = VoiceActivityDetector::new(VadConfig {
            start_threshold: 0.02,
            continue_threshold: 0.01,
            start_frames: 1,
            end_frames: 2,
        });
        let mut byte_vad = sample_vad.clone();
        assert_eq!(
            sample_vad.process_pcm16(&samples),
            byte_vad.process_pcm16_le_bytes(&bytes)
        );
    }
}
