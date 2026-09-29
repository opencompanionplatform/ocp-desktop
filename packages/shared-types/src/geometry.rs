//! Canonical desktop-global geometry.

use serde::{Deserialize, Serialize};
use std::ops::{Add, Sub};

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Point2 {
    pub x: f32,
    pub y: f32,
}

impl Point2 {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    #[must_use]
    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Vector2 {
    pub x: f32,
    pub y: f32,
}

impl Vector2 {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    #[must_use]
    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    #[must_use]
    pub fn length(self) -> f32 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}

impl Add<Vector2> for Point2 {
    type Output = Point2;

    fn add(self, rhs: Vector2) -> Self::Output {
        Point2::new(self.x + rhs.x, self.y + rhs.y)
    }
}

impl Sub<Point2> for Point2 {
    type Output = Vector2;

    fn sub(self, rhs: Point2) -> Self::Output {
        Vector2::new(self.x - rhs.x, self.y - rhs.y)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Size2 {
    pub width: f32,
    pub height: f32,
}

impl Size2 {
    #[must_use]
    pub const fn new(width: f32, height: f32) -> Self {
        Self { width, height }
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub origin: Point2,
    pub size: Size2,
}

impl Rect {
    #[must_use]
    pub const fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            origin: Point2::new(x, y),
            size: Size2::new(width, height),
        }
    }

    #[must_use]
    pub const fn left(self) -> f32 {
        self.origin.x
    }

    #[must_use]
    pub const fn top(self) -> f32 {
        self.origin.y
    }

    #[must_use]
    pub const fn right(self) -> f32 {
        self.origin.x + self.size.width
    }

    #[must_use]
    pub const fn bottom(self) -> f32 {
        self.origin.y + self.size.height
    }

    #[must_use]
    pub fn center(self) -> Point2 {
        Point2::new(
            self.origin.x + self.size.width * 0.5,
            self.origin.y + self.size.height * 0.5,
        )
    }

    #[must_use]
    pub fn contains(self, point: Point2) -> bool {
        point.x >= self.left()
            && point.x <= self.right()
            && point.y >= self.top()
            && point.y <= self.bottom()
    }

    #[must_use]
    pub fn intersects(self, other: Self) -> bool {
        self.left() < other.right()
            && self.right() > other.left()
            && self.top() < other.bottom()
            && self.bottom() > other.top()
    }
}

/// Alias-like wrapper used when semantics require a bounded region.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Bounds(pub Rect);

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Transform2 {
    pub translation: Vector2,
    pub scale: Vector2,
    pub rotation_radians: f32,
}

impl Default for Transform2 {
    fn default() -> Self {
        Self {
            translation: Vector2::ZERO,
            scale: Vector2::new(1.0, 1.0),
            rotation_radians: 0.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HorizontalDirection {
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VerticalDirection {
    Up,
    Down,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Orientation {
    Horizontal,
    Vertical,
    Free,
}
