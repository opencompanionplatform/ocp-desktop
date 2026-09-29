use ocp_shared_types::Vector2;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct PhysicsConfig {
    pub gravity: Vector2,
    pub terminal_velocity: f32,
    pub contact_epsilon: f32,
    pub max_step_seconds: f32,
}

impl Default for PhysicsConfig {
    fn default() -> Self {
        Self {
            gravity: Vector2::new(0.0, 1_800.0),
            terminal_velocity: 1_600.0,
            contact_epsilon: 0.5,
            max_step_seconds: 1.0 / 30.0,
        }
    }
}
