#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DesktopLogicalPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DesktopLogicalRect {
    pub left: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
}

impl DesktopLogicalRect {
    #[must_use]
    pub fn contains(self, point: DesktopLogicalPoint) -> bool {
        point.x >= self.left
            && point.x < self.left + self.width
            && point.y >= self.top
            && point.y < self.top + self.height
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PhysicalRect {
    pub left: i32,
    pub top: i32,
    pub width: i32,
    pub height: i32,
}

impl PhysicalRect {
    #[must_use]
    pub const fn center(self) -> (i32, i32) {
        (self.left + self.width / 2, self.top + self.height / 2)
    }

    #[must_use]
    pub const fn contains(self, point: (i32, i32)) -> bool {
        point.0 >= self.left
            && point.0 < self.left + self.width
            && point.1 >= self.top
            && point.1 < self.top + self.height
    }
}

/// Runtime contract for primary Hover-menu rows. Only the first three rows
/// own a flyout; every other row is a direct Runtime command.
#[must_use]
pub const fn hover_menu_submenu_mode(row: i32) -> Option<i32> {
    match row {
        0..=2 => Some(row),
        _ => None,
    }
}

/// Returns the Runtime command for a direct Hover-menu action. Provider and
/// update controls stay in Control Center; the production Hover menu only
/// exposes high-frequency companion actions.
#[must_use]
pub const fn hover_menu_primary_action(row: i32) -> Option<&'static str> {
    match row {
        3 => Some("chat"),
        4 => Some("settings"),
        5 => Some("change-character"),
        6 => Some("hide-to-tray"),
        7 => Some("exit"),
        _ => None,
    }
}

/// Returns a Runtime request for an item in the selected Hover-menu flyout.
/// The native process never changes sound state locally; both sound entries
/// are requests awaiting the Runtime acknowledgement snapshot.
#[must_use]
pub const fn hover_menu_submenu_action(mode: i32, row: i32) -> Option<&'static str> {
    match mode {
        0 => match row {
            0 => Some("idle"),
            1 => Some("wave"),
            2 => Some("think"),
            3 => Some("sit"),
            _ => None,
        },
        1 => match row {
            0 => Some("size-25"),
            1 => Some("size-50"),
            2 => Some("size-75"),
            3 => Some("size-100"),
            4 => Some("size-125"),
            _ => None,
        },
        2 => match row {
            0 => Some("sound-master-toggle"),
            1 => Some("sound-sfx-toggle"),
            _ => None,
        },
        _ => None,
    }
}

/// Normalizes the Runtime locale to the native hover-menu language contract.
/// Unknown locales intentionally fall back to English.
#[must_use]
pub fn normalize_hover_language(language: &str) -> &'static str {
    let normalized = language.trim().as_bytes();
    let thai_prefix = normalized.len() >= 2
        && normalized[0].eq_ignore_ascii_case(&b't')
        && normalized[1].eq_ignore_ascii_case(&b'h')
        && (normalized.len() == 2
            || normalized
                .get(2)
                .is_some_and(|separator| *separator == b'-' || *separator == b'_'));
    if thai_prefix {
        "th"
    } else {
        "en"
    }
}

/// Returns presentation text only. Runtime action IDs and icon lookup remain
/// language-neutral, so changing locale cannot alter click routing.
#[must_use]
pub fn localized_hover_label<'a>(language: &str, label: &'a str) -> &'a str {
    if normalize_hover_language(language) != "th" {
        return label;
    }
    match label {
        "OCP Companion" => "คู่หูบนหน้าจอ",
        "Quick actions" => "เมนูลัด",
        "Actions" => "ท่าทาง",
        "Choose a pose" => "เลือกท่าทาง",
        "Size" => "ขนาด",
        "Visual scale" => "ขนาดตัวละคร",
        "Sound" => "เสียง",
        "Runtime audio" => "การตั้งค่าเสียง",
        "Chat" => "แชต",
        "Settings" => "การตั้งค่า",
        "Change Character" => "เปลี่ยนตัวละคร",
        "Hide to Tray" => "ซ่อนไปที่ Tray",
        "Exit" => "ออกจาก OCP",
        "Characters" => "ตัวละคร",
        "Choose companion" => "เลือกคู่หู",
        "Mute all" => "ปิดเสียงทั้งหมด",
        "Unmute all" => "เปิดเสียงทั้งหมด",
        "Character SFX" => "เสียงตัวละคร",
        "Character SFX off" => "เสียงตัวละคร: ปิด",
        "Idle" => "พัก",
        "Wave" => "โบกมือ",
        "Think" => "คิด",
        "Sit" => "นั่ง",
        "Close" => "ปิด",
        _ => label,
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MonitorDescriptor {
    pub id: usize,
    pub logical: DesktopLogicalRect,
    pub physical: PhysicalRect,
    pub dpi: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NativePlacement {
    pub monitor_id: usize,
    pub bounds: PhysicalRect,
}

/// Returns true when the adopted Godot surface no longer matches the native
/// controller. Windows can deliver a delayed DPI resize to the cross-process
/// render HWND after the controller has already completed a monitor handoff.
#[must_use]
pub fn render_surface_needs_sync(controller: PhysicalRect, render: PhysicalRect) -> bool {
    controller != render
}

/// G7 render-host contract. The native window owns the physical outer bounds;
/// rendering is constrained to its client area and never receives virtual-
/// desktop coordinates. The canonical feet point remains unchanged.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RenderHostLayout {
    pub native_bounds: PhysicalRect,
    pub client_size: (i32, i32),
    pub canonical_feet: DesktopLogicalPoint,
}

#[must_use]
pub fn render_host_layout(
    placement: NativePlacement,
    canonical_feet: DesktopLogicalPoint,
    client_inset: (i32, i32),
) -> RenderHostLayout {
    let inset_x = client_inset.0.max(0).min(placement.bounds.width / 2);
    let inset_y = client_inset.1.max(0).min(placement.bounds.height / 2);
    RenderHostLayout {
        native_bounds: placement.bounds,
        client_size: (
            (placement.bounds.width - inset_x * 2).max(1),
            (placement.bounds.height - inset_y * 2).max(1),
        ),
        canonical_feet,
    }
}

#[must_use]
pub fn render_host_preserves_canonical_feet(
    before: RenderHostLayout,
    after: RenderHostLayout,
) -> bool {
    before.canonical_feet == after.canonical_feet
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderHostToken(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderHostLifecycle {
    Created,
    Ready,
    Resized { width: i32, height: i32 },
    Hidden,
    Visible,
    Detached,
}

#[must_use]
pub fn validate_render_host_token(token: RenderHostToken) -> bool {
    token.0 != 0
}

#[must_use]
pub fn advance_render_host(
    current: RenderHostLifecycle,
    event: RenderHostLifecycle,
    token: RenderHostToken,
) -> Option<RenderHostLifecycle> {
    if !validate_render_host_token(token) {
        return None;
    }
    match (current, event) {
        (RenderHostLifecycle::Created, RenderHostLifecycle::Ready)
        | (RenderHostLifecycle::Ready, RenderHostLifecycle::Hidden)
        | (RenderHostLifecycle::Hidden, RenderHostLifecycle::Visible)
        | (RenderHostLifecycle::Ready, RenderHostLifecycle::Visible)
        | (RenderHostLifecycle::Visible, RenderHostLifecycle::Hidden)
        | (RenderHostLifecycle::Ready, RenderHostLifecycle::Detached)
        | (RenderHostLifecycle::Hidden, RenderHostLifecycle::Detached)
        | (RenderHostLifecycle::Visible, RenderHostLifecycle::Detached) => Some(event),
        (RenderHostLifecycle::Ready, RenderHostLifecycle::Resized { width, height })
        | (RenderHostLifecycle::Resized { .. }, RenderHostLifecycle::Resized { width, height })
            if width > 0 && height > 0 =>
        {
            Some(RenderHostLifecycle::Resized { width, height })
        }
        (RenderHostLifecycle::Resized { .. }, RenderHostLifecycle::Hidden)
        | (RenderHostLifecycle::Resized { .. }, RenderHostLifecycle::Visible)
        | (RenderHostLifecycle::Resized { .. }, RenderHostLifecycle::Detached) => Some(event),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuxiliaryPlacement {
    Above,
    Right,
    Below,
    Left,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuxiliaryBounds {
    pub placement: AuxiliaryPlacement,
    pub bounds: PhysicalRect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuxiliaryGroupBounds {
    pub bubble: AuxiliaryBounds,
    pub menu: AuxiliaryBounds,
}

#[must_use]
pub const fn physical_rects_overlap(left: PhysicalRect, right: PhysicalRect) -> bool {
    left.left < right.left + right.width
        && left.left + left.width > right.left
        && left.top < right.top + right.height
        && left.top + left.height > right.top
}

/// Expands a native visual hit target into a drag-safe region while retaining
/// the monitor work-area bounds. Popup geometry must avoid this region so a
/// small companion stays draggable even at a screen edge.
#[must_use]
pub fn expand_physical_rect_within(
    rect: PhysicalRect,
    padding: i32,
    work_area: PhysicalRect,
) -> PhysicalRect {
    let padding = padding.max(0);
    let left = (rect.left - padding).max(work_area.left);
    let top = (rect.top - padding).max(work_area.top);
    let right = (rect.left + rect.width + padding).min(work_area.left + work_area.width);
    let bottom = (rect.top + rect.height + padding).min(work_area.top + work_area.height);
    PhysicalRect {
        left,
        top,
        width: (right - left).max(1),
        height: (bottom - top).max(1),
    }
}

fn clamped_auxiliary_bounds(
    placement: AuxiliaryPlacement,
    requested_left: i32,
    requested_top: i32,
    desired_size: (i32, i32),
    work_area: PhysicalRect,
) -> AuxiliaryBounds {
    let width = desired_size.0.min(work_area.width).max(1);
    let height = desired_size.1.min(work_area.height).max(1);
    AuxiliaryBounds {
        placement,
        bounds: PhysicalRect {
            left: requested_left.clamp(work_area.left, work_area.left + work_area.width - width),
            top: requested_top.clamp(work_area.top, work_area.top + work_area.height - height),
            width,
            height,
        },
    }
}

fn auxiliary_candidates(
    anchor: PhysicalRect,
    desired_size: (i32, i32),
    work_area: PhysicalRect,
    gap: i32,
) -> [AuxiliaryBounds; 4] {
    let width = desired_size.0.min(work_area.width).max(1);
    let height = desired_size.1.min(work_area.height).max(1);
    [
        clamped_auxiliary_bounds(
            AuxiliaryPlacement::Right,
            anchor.left + anchor.width + gap,
            anchor.top + anchor.height / 2 - height / 2,
            (width, height),
            work_area,
        ),
        clamped_auxiliary_bounds(
            AuxiliaryPlacement::Left,
            anchor.left - gap - width,
            anchor.top + anchor.height / 2 - height / 2,
            (width, height),
            work_area,
        ),
        clamped_auxiliary_bounds(
            AuxiliaryPlacement::Above,
            anchor.left + anchor.width / 2 - width / 2,
            anchor.top - gap - height,
            (width, height),
            work_area,
        ),
        clamped_auxiliary_bounds(
            AuxiliaryPlacement::Below,
            anchor.left + anchor.width / 2 - width / 2,
            anchor.top + anchor.height + gap,
            (width, height),
            work_area,
        ),
    ]
}

/// Finds a clamped popup placement that avoids every forbidden rectangle.
/// Candidate selection intentionally happens after clamping: a requested
/// right-hand popup can become an overlapping rectangle at a screen edge if
/// the collision check happens before the clamp.
#[must_use]
pub fn place_auxiliary_avoiding(
    anchor: PhysicalRect,
    desired_size: (i32, i32),
    work_area: PhysicalRect,
    gap: i32,
    forbidden: &[PhysicalRect],
) -> Option<AuxiliaryBounds> {
    auxiliary_candidates(anchor, desired_size, work_area, gap)
        .into_iter()
        .find(|candidate| {
            forbidden.iter().all(|forbidden_bounds| {
                !physical_rects_overlap(candidate.bounds, *forbidden_bounds)
            })
        })
}

/// First tries the normal hover menu and then a compact-width variant. If the
/// work area cannot safely fit either, callers must keep the popup hidden.
#[must_use]
pub fn place_drag_safe_auxiliary_menu(
    drag_safe_bounds: PhysicalRect,
    desired_size: (i32, i32),
    compact_size: (i32, i32),
    work_area: PhysicalRect,
    gap: i32,
) -> Option<AuxiliaryBounds> {
    place_auxiliary_avoiding(
        drag_safe_bounds,
        desired_size,
        work_area,
        gap,
        &[drag_safe_bounds],
    )
    .or_else(|| {
        place_auxiliary_avoiding(
            drag_safe_bounds,
            compact_size,
            work_area,
            gap,
            &[drag_safe_bounds],
        )
    })
}

/// Place Size/Sound flyouts beside their parent row.
///
/// The preferred direction is right, then left. Vertical position is always
/// clamped to the monitor work area. If neither side has enough horizontal
/// room, choose the side with more space and clamp the popup rather than
/// dropping it completely.
pub fn place_side_submenu(
    anchor: PhysicalRect,
    desired_size: (i32, i32),
    work_area: PhysicalRect,
    gap: i32,
) -> AuxiliaryBounds {
    let width = desired_size.0.min(work_area.width).max(1);
    let height = desired_size.1.min(work_area.height).max(1);
    let work_right = work_area.left + work_area.width;
    let anchor_right = anchor.left + anchor.width;

    let right_left = anchor_right + gap;
    let left_left = anchor.left - gap - width;
    let right_fits = right_left + width <= work_right;
    let left_fits = left_left >= work_area.left;

    let (placement, requested_left) = if right_fits {
        (AuxiliaryPlacement::Right, right_left)
    } else if left_fits {
        (AuxiliaryPlacement::Left, left_left)
    } else {
        let room_right = (work_right - right_left).max(0);
        let room_left = (anchor.left - gap - work_area.left).max(0);
        if room_right >= room_left {
            (AuxiliaryPlacement::Right, right_left)
        } else {
            (AuxiliaryPlacement::Left, left_left)
        }
    };

    clamped_auxiliary_bounds(
        placement,
        requested_left,
        anchor.top,
        (width, height),
        work_area,
    )
}

/// Maps a client-space pointer Y coordinate to a popup row while reserving a
/// non-interactive visual header. Native drawing and click dispatch share this
/// helper so a redesigned header cannot shift a menu action by one row.
#[must_use]
pub fn popup_row_from_client_y(
    client_y: i32,
    header_height: i32,
    row_height: i32,
    row_count: i32,
) -> Option<i32> {
    if row_height <= 0 || row_count <= 0 {
        return None;
    }
    let relative_y = client_y - header_height;
    if relative_y < 0 {
        return None;
    }
    let row = relative_y / row_height;
    (row < row_count).then_some(row)
}

/// Returns the physical bounds for a visual popup row.  Popup placement uses
/// this to keep a child panel visually attached to the row that opened it,
/// while click dispatch continues to use [`popup_row_from_client_y`].
#[must_use]
pub fn popup_row_bounds(
    popup_bounds: PhysicalRect,
    header_height: i32,
    row_height: i32,
    row_index: i32,
) -> Option<PhysicalRect> {
    if header_height < 0 || row_height <= 0 || row_index < 0 {
        return None;
    }
    let top = popup_bounds
        .top
        .saturating_add(header_height)
        .saturating_add(row_height.saturating_mul(row_index));
    let bottom = top
        .saturating_add(row_height)
        .min(popup_bounds.top.saturating_add(popup_bounds.height.max(0)));
    (top < bottom).then_some(PhysicalRect {
        left: popup_bounds.left,
        top,
        width: popup_bounds.width.max(0),
        height: bottom - top,
    })
}

/// Maps a client-space X coordinate into an evenly divided horizontal popup
/// segment. The right boundary is exclusive, matching `PhysicalRect` and the
/// row hit-map contract used by the vertical native menus.
#[must_use]
pub fn popup_segment_from_client_x(
    client_x: i32,
    content_left: i32,
    content_right: i32,
    segment_count: i32,
) -> Option<i32> {
    let width = content_right - content_left;
    if width <= 0 || segment_count <= 0 || client_x < content_left || client_x >= content_right {
        return None;
    }
    let segment = ((client_x - content_left) * segment_count) / width;
    (segment < segment_count).then_some(segment)
}

/// Returns the native size-submenu segment for a Runtime-approved companion
/// presentation scale. The native host mirrors this state but never accepts a
/// scale outside the Runtime contract.
#[must_use]
pub fn companion_scale_preset_index(scale: f64) -> Option<usize> {
    const PRESETS: [f64; 5] = [0.25, 0.50, 0.75, 1.00, 1.25];
    if !scale.is_finite() {
        return None;
    }
    PRESETS
        .iter()
        .position(|preset| (scale - preset).abs() <= f64::EPSILON * 8.0)
}

/// Converts conventional RGB channel values into a Win32 COLORREF.
/// COLORREF stores the bytes as `0x00BBGGRR`.
#[must_use]
pub const fn colorref_rgb(red: u8, green: u8, blue: u8) -> u32 {
    (red as u32) | ((green as u32) << 8) | ((blue as u32) << 16)
}

/// Auxiliary menu windows paint their full client area, so their first paint
/// must use the stable surface color rather than the magenta transparency key.
/// Shaped/transparent surfaces still retain their explicit color key.
#[must_use]
pub const fn auxiliary_prepaint_color(
    is_opaque_auxiliary: bool,
    surface_color: u32,
    transparent_key: u32,
) -> u32 {
    if is_opaque_auxiliary {
        surface_color
    } else {
        transparent_key
    }
}

/// Hover is an interaction-state cue, not an animated ambient aura. Keep the
/// primary accent stable so Liquid/Glass themes never flash through a pink or
/// violet secondary accent while the pointer moves.
#[must_use]
pub const fn hover_accent_color(primary: u32, _secondary: u32) -> u32 {
    primary
}

/// The transparent drag/input proxy remains available while hover UI is open so
/// the character can still receive click/drag gestures. Popup HWNDs are kept
/// above it explicitly in the native z-order instead of disabling input here.
#[must_use]
pub const fn input_proxy_should_be_visible(
    owner_visible: bool,
    render_visible: bool,
    click_through: bool,
) -> bool {
    owner_visible && render_visible && !click_through
}

#[must_use]
pub fn place_auxiliary_window(
    owner: PhysicalRect,
    desired_size: (i32, i32),
    work_area: PhysicalRect,
    gap: i32,
) -> AuxiliaryBounds {
    let width = desired_size.0.min(work_area.width).max(1);
    let height = desired_size.1.min(work_area.height).max(1);
    let above_top = owner.top - gap - height;
    let (placement, requested_left, requested_top) = if above_top >= work_area.top {
        (
            AuxiliaryPlacement::Above,
            owner.left + owner.width / 2 - width / 2,
            above_top,
        )
    } else {
        (
            AuxiliaryPlacement::Right,
            owner.left + owner.width + gap,
            owner.top + owner.height / 2 - height / 2,
        )
    };
    AuxiliaryBounds {
        placement,
        bounds: PhysicalRect {
            left: requested_left.clamp(work_area.left, work_area.left + work_area.width - width),
            top: requested_top.clamp(work_area.top, work_area.top + work_area.height - height),
            width,
            height,
        },
    }
}

#[must_use]
pub fn place_auxiliary_window_right(
    owner: PhysicalRect,
    desired_size: (i32, i32),
    work_area: PhysicalRect,
    gap: i32,
) -> AuxiliaryBounds {
    let width = desired_size.0.min(work_area.width).max(1);
    let height = desired_size.1.min(work_area.height).max(1);
    AuxiliaryBounds {
        placement: AuxiliaryPlacement::Right,
        bounds: PhysicalRect {
            left: (owner.left + owner.width + gap)
                .clamp(work_area.left, work_area.left + work_area.width - width),
            top: (owner.top + owner.height / 2 - height / 2)
                .clamp(work_area.top, work_area.top + work_area.height - height),
            width,
            height,
        },
    }
}

#[must_use]
pub fn place_auxiliary_group(
    owner: PhysicalRect,
    bubble_size: (i32, i32),
    menu_size: (i32, i32),
    work_area: PhysicalRect,
    gap: i32,
) -> AuxiliaryGroupBounds {
    let bubble = place_auxiliary_window(owner, bubble_size, work_area, gap);
    let width = menu_size.0.min(work_area.width).max(1);
    let height = menu_size.1.min(work_area.height).max(1);
    let clamp = |left: i32, top: i32| PhysicalRect {
        left: left.clamp(work_area.left, work_area.left + work_area.width - width),
        top: top.clamp(work_area.top, work_area.top + work_area.height - height),
        width,
        height,
    };
    let candidates = [
        clamp(
            owner.left + owner.width + gap,
            owner.top + owner.height / 2 - height / 2,
        ),
        clamp(
            owner.left + owner.width / 2 - width / 2,
            owner.top + owner.height + gap,
        ),
        clamp(
            owner.left - gap - width,
            owner.top + owner.height / 2 - height / 2,
        ),
        clamp(
            owner.left + owner.width / 2 - width / 2,
            owner.top - gap - height,
        ),
    ];
    let menu_bounds = candidates
        .into_iter()
        .find(|candidate| {
            !physical_rects_overlap(*candidate, owner)
                && !physical_rects_overlap(*candidate, bubble.bounds)
        })
        .unwrap_or(candidates[0]);
    AuxiliaryGroupBounds {
        bubble,
        menu: AuxiliaryBounds {
            placement: if menu_bounds.left >= owner.left + owner.width {
                AuxiliaryPlacement::Right
            } else {
                AuxiliaryPlacement::Above
            },
            bounds: menu_bounds,
        },
    }
}

/// Gate G3 derivation used by the isolated spike. Windows monitor origins are
/// preserved; only extents are converted from physical pixels to desktop
/// logical units. Production integration must replace this derivation with
/// the frozen sensor/coordinator monitor mapping contract.
#[must_use]
pub fn derive_logical_monitor(id: usize, physical: PhysicalRect, dpi: u32) -> MonitorDescriptor {
    let scale = f64::from(dpi.max(1)) / 96.0;
    MonitorDescriptor {
        id,
        logical: DesktopLogicalRect {
            left: f64::from(physical.left),
            top: f64::from(physical.top),
            width: f64::from(physical.width) / scale,
            height: f64::from(physical.height) / scale,
        },
        physical,
        dpi: dpi.max(1),
    }
}

#[must_use]
pub fn monitor_for_logical_point(
    point: DesktopLogicalPoint,
    monitors: &[MonitorDescriptor],
) -> Option<MonitorDescriptor> {
    monitors
        .iter()
        .copied()
        .find(|monitor| monitor.logical.contains(point))
}

#[must_use]
pub fn canonical_feet_to_native_placement(
    feet: DesktopLogicalPoint,
    logical_size: (f64, f64),
    monitors: &[MonitorDescriptor],
) -> Option<NativePlacement> {
    canonical_anchor_to_native_placement(feet, logical_size, (0.5, 1.0), monitors)
}

/// Maps a canonical desktop contact point to a native window rectangle using
/// a normalized artwork contact anchor. Physics remains unaware of sprite
/// padding, pose proportions, and presentation scale.
#[must_use]
pub fn canonical_anchor_to_native_placement(
    contact: DesktopLogicalPoint,
    logical_size: (f64, f64),
    normalized_anchor: (f64, f64),
    monitors: &[MonitorDescriptor],
) -> Option<NativePlacement> {
    let monitor = monitor_for_logical_point(contact, monitors)?;
    let relative_x = (contact.x - monitor.logical.left) / monitor.logical.width;
    let relative_y = (contact.y - monitor.logical.top) / monitor.logical.height;
    let physical_feet_x =
        f64::from(monitor.physical.left) + relative_x * f64::from(monitor.physical.width);
    let physical_feet_y =
        f64::from(monitor.physical.top) + relative_y * f64::from(monitor.physical.height);
    let width = logical_extent_to_physical(logical_size.0.round() as i32, monitor.dpi);
    let height = logical_extent_to_physical(logical_size.1.round() as i32, monitor.dpi);
    let anchor_x = normalized_anchor.0.clamp(0.0, 1.0);
    let anchor_y = normalized_anchor.1.clamp(0.0, 1.0);
    Some(NativePlacement {
        monitor_id: monitor.id,
        bounds: PhysicalRect {
            left: (physical_feet_x - f64::from(width) * anchor_x).round() as i32,
            top: (physical_feet_y - f64::from(height) * anchor_y).round() as i32,
            width,
            height,
        },
    })
}

/// Maps a canonical desktop contact point to a native rectangle whose client
/// size is already expressed in physical pixels. Transparent companion
/// surfaces use this mapping to keep the same rendered size across monitors
/// with different DPI values.
#[must_use]
pub fn canonical_anchor_to_fixed_physical_placement(
    contact: DesktopLogicalPoint,
    physical_size: (i32, i32),
    normalized_anchor: (f64, f64),
    monitors: &[MonitorDescriptor],
) -> Option<NativePlacement> {
    let monitor = monitor_for_logical_point(contact, monitors)?;
    let relative_x = (contact.x - monitor.logical.left) / monitor.logical.width;
    let relative_y = (contact.y - monitor.logical.top) / monitor.logical.height;
    let physical_contact_x =
        f64::from(monitor.physical.left) + relative_x * f64::from(monitor.physical.width);
    let physical_contact_y =
        f64::from(monitor.physical.top) + relative_y * f64::from(monitor.physical.height);
    let width = physical_size.0.max(1);
    let height = physical_size.1.max(1);
    let anchor_x = normalized_anchor.0.clamp(0.0, 1.0);
    let anchor_y = normalized_anchor.1.clamp(0.0, 1.0);
    Some(NativePlacement {
        monitor_id: monitor.id,
        bounds: PhysicalRect {
            left: (physical_contact_x - f64::from(width) * anchor_x).round() as i32,
            top: (physical_contact_y - f64::from(height) * anchor_y).round() as i32,
            width,
            height,
        },
    })
}

/// Aligns a grounded visual contact with the monitor work-area bottom.
///
/// Desktop World remains authoritative for the canonical logical state, but
/// Windows can virtualize `rcWork` differently for DPI-unaware and PMv2
/// processes. The native presentation host therefore uses its own physical
/// work-area edge only after Physics has explicitly declared the companion
/// grounded. Airborne, window-top, and wall attachments must not use this
/// correction.
#[must_use]
pub fn align_grounded_placement_to_work_area(
    mut placement: NativePlacement,
    work_area: PhysicalRect,
    normalized_anchor_y: f64,
) -> NativePlacement {
    let anchor_y = normalized_anchor_y.clamp(0.0, 1.0);
    placement.bounds.top = (f64::from(work_area.top + work_area.height)
        - f64::from(placement.bounds.height) * anchor_y)
        .round() as i32;
    placement
}

/// Returns whether a canonical grounded state represents the monitor floor.
/// Window-top sitting is also grounded in Desktop Physics, but its canonical
/// feet must remain on the window surface instead of being corrected to the
/// monitor work-area bottom.
#[must_use]
pub fn should_align_grounded_to_work_area(
    attachment_state: &str,
    movement_state: &str,
    surface_kind: &str,
) -> bool {
    // Only the physical desktop floor gets a presentation-side correction.
    // Taskbar/dock tops are real Physics surfaces; their canonical contact
    // point must be preserved exactly. Re-aligning them to rcWork.bottom can
    // turn a ledge-transfer/hang into a visible drop onto the taskbar.
    attachment_state == "grounded" && movement_state != "sitting" && surface_kind == "desktop_floor"
}

#[must_use]
pub fn native_bounds_to_canonical_feet(
    bounds: PhysicalRect,
    monitors: &[MonitorDescriptor],
) -> Option<(usize, DesktopLogicalPoint)> {
    native_bounds_to_canonical_anchor(bounds, (0.5, 1.0), monitors)
}

#[must_use]
pub fn native_bounds_to_canonical_anchor(
    bounds: PhysicalRect,
    normalized_anchor: (f64, f64),
    monitors: &[MonitorDescriptor],
) -> Option<(usize, DesktopLogicalPoint)> {
    let center = bounds.center();
    let monitor = monitors
        .iter()
        .copied()
        .find(|monitor| monitor.physical.contains(center))?;
    let anchor_x = normalized_anchor.0.clamp(0.0, 1.0);
    let anchor_y = normalized_anchor.1.clamp(0.0, 1.0);
    let physical_feet_x = f64::from(bounds.left) + f64::from(bounds.width) * anchor_x;
    let physical_feet_y = f64::from(bounds.top) + f64::from(bounds.height) * anchor_y;
    let relative_x =
        (physical_feet_x - f64::from(monitor.physical.left)) / f64::from(monitor.physical.width);
    let relative_y =
        (physical_feet_y - f64::from(monitor.physical.top)) / f64::from(monitor.physical.height);
    Some((
        monitor.id,
        DesktopLogicalPoint {
            x: monitor.logical.left + relative_x * monitor.logical.width,
            y: monitor.logical.top + relative_y * monitor.logical.height,
        },
    ))
}

#[must_use]
pub fn logical_extent_to_physical(logical: i32, dpi: u32) -> i32 {
    ((i64::from(logical) * i64::from(dpi.max(1)) + 48) / 96) as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hover_accent_never_animates_into_secondary_pink_or_violet() {
        let primary = colorref_rgb(47, 125, 225);
        let secondary = colorref_rgb(194, 111, 233);
        assert_eq!(hover_accent_color(primary, secondary), primary);
    }

    #[test]
    fn auxiliary_menu_prepaint_never_uses_magenta_transparency_key() {
        let surface = colorref_rgb(10, 28, 48);
        let magenta_key = 0x00FF00FF;
        assert_eq!(
            auxiliary_prepaint_color(true, surface, magenta_key),
            surface
        );
        assert_eq!(
            auxiliary_prepaint_color(false, surface, magenta_key),
            magenta_key
        );
    }

    #[test]
    fn input_proxy_stays_available_for_character_drag() {
        assert!(input_proxy_should_be_visible(true, true, false));
        assert!(!input_proxy_should_be_visible(true, true, true));
        assert!(!input_proxy_should_be_visible(false, true, false));
        assert!(!input_proxy_should_be_visible(true, false, false));
    }

    fn mixed_dpi_fixture() -> [MonitorDescriptor; 3] {
        [
            derive_logical_monitor(
                1,
                PhysicalRect {
                    left: 0,
                    top: 0,
                    width: 2880,
                    height: 1920,
                },
                192,
            ),
            derive_logical_monitor(
                2,
                PhysicalRect {
                    left: -1920,
                    top: 0,
                    width: 1920,
                    height: 1080,
                },
                96,
            ),
            derive_logical_monitor(
                3,
                PhysicalRect {
                    left: -3000,
                    top: -143,
                    width: 1080,
                    height: 1920,
                },
                96,
            ),
        ]
    }

    #[test]
    fn derives_mixed_dpi_logical_extents_without_rewriting_origins() {
        let monitors = mixed_dpi_fixture();
        assert_eq!(
            monitors[0].logical,
            DesktopLogicalRect {
                left: 0.0,
                top: 0.0,
                width: 1440.0,
                height: 960.0
            }
        );
        assert_eq!(
            monitors[1].logical,
            DesktopLogicalRect {
                left: -1920.0,
                top: 0.0,
                width: 1920.0,
                height: 1080.0
            }
        );
        assert_eq!(
            monitors[2].logical,
            DesktopLogicalRect {
                left: -3000.0,
                top: -143.0,
                width: 1080.0,
                height: 1920.0
            }
        );
    }

    #[test]
    fn maps_primary_canonical_feet_to_192_dpi_physical_bounds() {
        let placement = canonical_feet_to_native_placement(
            DesktopLogicalPoint { x: 640.0, y: 912.0 },
            (128.0, 128.0),
            &mixed_dpi_fixture(),
        )
        .unwrap();
        assert_eq!(placement.monitor_id, 1);
        assert_eq!(
            placement.bounds,
            PhysicalRect {
                left: 1152,
                top: 1568,
                width: 256,
                height: 256
            }
        );
    }

    #[test]
    fn maps_negative_origin_monitors_without_clamping_or_wrapping() {
        let monitors = mixed_dpi_fixture();
        let left = canonical_feet_to_native_placement(
            DesktopLogicalPoint {
                x: -960.0,
                y: 1032.0,
            },
            (128.0, 128.0),
            &monitors,
        )
        .unwrap();
        assert_eq!(left.monitor_id, 2);
        assert_eq!(
            left.bounds,
            PhysicalRect {
                left: -1024,
                top: 904,
                width: 128,
                height: 128
            }
        );

        let portrait = canonical_feet_to_native_placement(
            DesktopLogicalPoint {
                x: -2460.0,
                y: 1700.0,
            },
            (128.0, 128.0),
            &monitors,
        )
        .unwrap();
        assert_eq!(portrait.monitor_id, 3);
        assert_eq!(
            portrait.bounds,
            PhysicalRect {
                left: -2524,
                top: 1572,
                width: 128,
                height: 128
            }
        );
    }

    #[test]
    fn rejects_points_outside_the_declared_monitor_contract() {
        assert!(canonical_feet_to_native_placement(
            DesktopLogicalPoint {
                x: 5000.0,
                y: 5000.0
            },
            (128.0, 128.0),
            &mixed_dpi_fixture(),
        )
        .is_none());
    }

    #[test]
    fn drag_release_round_trips_canonical_feet_on_each_dpi() {
        let monitors = mixed_dpi_fixture();
        for feet in [
            DesktopLogicalPoint { x: 640.0, y: 912.0 },
            DesktopLogicalPoint {
                x: -960.0,
                y: 1032.0,
            },
            DesktopLogicalPoint {
                x: -2460.0,
                y: 1700.0,
            },
        ] {
            let placement =
                canonical_feet_to_native_placement(feet, (128.0, 128.0), &monitors).unwrap();
            let (monitor_id, round_trip) =
                native_bounds_to_canonical_feet(placement.bounds, &monitors).unwrap();
            assert_eq!(monitor_id, placement.monitor_id);
            assert!((round_trip.x - feet.x).abs() < 0.01);
            assert!((round_trip.y - feet.y).abs() < 0.01);
        }
    }

    #[test]
    fn pose_anchor_changes_only_native_bounds_and_round_trips_contact() {
        let monitors = mixed_dpi_fixture();
        let contact = DesktopLogicalPoint { x: 640.0, y: 500.0 };
        let placement =
            canonical_anchor_to_native_placement(contact, (192.0, 192.0), (0.5, 0.625), &monitors)
                .expect("anchored placement");
        let (_, round_trip) =
            native_bounds_to_canonical_anchor(placement.bounds, (0.5, 0.625), &monitors)
                .expect("anchored inverse");
        assert!((round_trip.x - contact.x).abs() < 0.01);
        assert!((round_trip.y - contact.y).abs() < 0.01);
    }

    #[test]
    fn dpi_conversion_is_final_and_deterministic() {
        assert_eq!(logical_extent_to_physical(128, 96), 128);
        assert_eq!(logical_extent_to_physical(128, 120), 160);
        assert_eq!(logical_extent_to_physical(128, 144), 192);
        assert_eq!(logical_extent_to_physical(128, 192), 256);
    }

    #[test]
    fn authored_logical_surface_scales_once_for_each_monitor_dpi() {
        let monitors = mixed_dpi_fixture();
        let primary = canonical_feet_to_native_placement(
            DesktopLogicalPoint { x: 640.0, y: 912.0 },
            (384.0, 384.0),
            &monitors,
        )
        .expect("primary placement");
        let secondary = canonical_feet_to_native_placement(
            DesktopLogicalPoint {
                x: -960.0,
                y: 1032.0,
            },
            (384.0, 384.0),
            &monitors,
        )
        .expect("secondary placement");

        assert_eq!((primary.bounds.width, primary.bounds.height), (768, 768));
        assert_eq!(
            (secondary.bounds.width, secondary.bounds.height),
            (384, 384)
        );
    }

    #[test]
    fn grounded_visual_contact_uses_physical_work_area_bottom() {
        let placement = NativePlacement {
            monitor_id: 1,
            bounds: PhysicalRect {
                left: 900,
                top: 1_008,
                width: 768,
                height: 768,
            },
        };
        let aligned = align_grounded_placement_to_work_area(
            placement,
            PhysicalRect {
                left: 0,
                top: 0,
                width: 2_880,
                height: 1_824,
            },
            0.95,
        );

        assert_eq!(aligned.bounds.top, 1_094);
        let contact_y = f64::from(aligned.bounds.top) + f64::from(aligned.bounds.height) * 0.95;
        assert!((contact_y - 1_824.0).abs() < 0.5);
    }

    #[test]
    fn window_top_sitting_keeps_its_canonical_contact() {
        assert!(!should_align_grounded_to_work_area(
            "grounded",
            "sitting",
            "window_top"
        ));
        assert!(should_align_grounded_to_work_area(
            "grounded",
            "stationary",
            "desktop_floor"
        ));
        assert!(!should_align_grounded_to_work_area(
            "grounded",
            "stationary",
            "window_top"
        ));
        assert!(!should_align_grounded_to_work_area(
            "airborne",
            "airborne-falling",
            ""
        ));
        assert!(!should_align_grounded_to_work_area(
            "grounded",
            "stationary",
            "taskbar_top"
        ));
        assert!(!should_align_grounded_to_work_area(
            "grounded",
            "stationary",
            "dock_top"
        ));

        // Regression from the real active-window trace: Physics placed the
        // feet at y=501, but the presentation host used to rewrite every
        // grounded contact to the monitor floor at y=912.
        let monitors = mixed_dpi_fixture();
        let contact = DesktopLogicalPoint { x: 856.0, y: 501.0 };
        let placement =
            canonical_anchor_to_native_placement(contact, (384.0, 384.0), (0.5, 1.0), &monitors)
                .expect("active-window sitting placement");
        let displayed = if should_align_grounded_to_work_area("grounded", "sitting", "window_top") {
            align_grounded_placement_to_work_area(
                placement,
                PhysicalRect {
                    left: 0,
                    top: 0,
                    width: 2_880,
                    height: 1_824,
                },
                1.0,
            )
        } else {
            placement
        };
        let (_, displayed_contact) =
            native_bounds_to_canonical_anchor(displayed.bounds, (0.5, 1.0), &monitors)
                .expect("displayed active-window contact");
        assert!((displayed_contact.y - 501.0).abs() < 0.01);
        assert!((displayed_contact.y - 912.0).abs() > 400.0);
    }

    #[test]
    fn fixed_physical_surface_keeps_size_and_contact_across_mixed_dpi_monitors() {
        let monitors = mixed_dpi_fixture();
        for feet in [
            DesktopLogicalPoint { x: 640.0, y: 912.0 },
            DesktopLogicalPoint {
                x: -960.0,
                y: 1032.0,
            },
        ] {
            let placement = canonical_anchor_to_fixed_physical_placement(
                feet,
                (384, 384),
                (0.5, 1.0),
                &monitors,
            )
            .expect("fixed physical placement");
            assert_eq!(
                (placement.bounds.width, placement.bounds.height),
                (384, 384)
            );
            let (_, round_trip) =
                native_bounds_to_canonical_anchor(placement.bounds, (0.5, 1.0), &monitors)
                    .expect("fixed physical round trip");
            assert!((round_trip.x - feet.x).abs() < 0.01);
            assert!((round_trip.y - feet.y).abs() < 0.01);
        }
    }

    #[test]
    fn delayed_render_dpi_resize_requires_controller_reconciliation() {
        let controller = PhysicalRect {
            left: 100,
            top: 200,
            width: 768,
            height: 768,
        };
        assert!(!render_surface_needs_sync(controller, controller));
        assert!(render_surface_needs_sync(
            controller,
            PhysicalRect {
                width: 1536,
                height: 1536,
                ..controller
            }
        ));
        assert!(render_surface_needs_sync(
            controller,
            PhysicalRect {
                width: 384,
                height: 384,
                ..controller
            }
        ));
    }

    #[test]
    fn auxiliary_prefers_above_and_clamps_to_work_area() {
        let result = place_auxiliary_window(
            PhysicalRect {
                left: -1100,
                top: 500,
                width: 128,
                height: 128,
            },
            (220, 80),
            PhysicalRect {
                left: -1920,
                top: 0,
                width: 1920,
                height: 1040,
            },
            8,
        );
        assert_eq!(result.placement, AuxiliaryPlacement::Above);
        assert_eq!(
            result.bounds,
            PhysicalRect {
                left: -1146,
                top: 412,
                width: 220,
                height: 80
            }
        );

        let clamped = place_auxiliary_window(
            PhysicalRect {
                left: -1920,
                top: 500,
                width: 128,
                height: 128,
            },
            (220, 80),
            PhysicalRect {
                left: -1920,
                top: 0,
                width: 1920,
                height: 1040,
            },
            8,
        );
        assert_eq!(clamped.bounds.left, -1920);
    }

    #[test]
    fn auxiliary_falls_back_to_right_when_above_is_unavailable() {
        let result = place_auxiliary_window(
            PhysicalRect {
                left: 100,
                top: 10,
                width: 256,
                height: 256,
            },
            (180, 160),
            PhysicalRect {
                left: 0,
                top: 0,
                width: 2880,
                height: 1840,
            },
            16,
        );
        assert_eq!(result.placement, AuxiliaryPlacement::Right);
        assert_eq!(result.bounds.left, 372);
        assert_eq!(result.bounds.top, 58);
    }

    #[test]
    fn menu_can_request_a_distinct_right_hand_anchor() {
        let result = place_auxiliary_window_right(
            PhysicalRect {
                left: 100,
                top: 500,
                width: 256,
                height: 256,
            },
            (180, 160),
            PhysicalRect {
                left: 0,
                top: 0,
                width: 2880,
                height: 1840,
            },
            16,
        );
        assert_eq!(result.placement, AuxiliaryPlacement::Right);
        assert_eq!(
            result.bounds,
            PhysicalRect {
                left: 372,
                top: 548,
                width: 180,
                height: 160
            }
        );
    }

    #[test]
    fn grouped_auxiliaries_do_not_overlap_at_top_left_work_area_edge() {
        let owner = PhysicalRect {
            left: 0,
            top: 0,
            width: 256,
            height: 256,
        };
        let group = place_auxiliary_group(
            owner,
            (440, 160),
            (360, 320),
            PhysicalRect {
                left: 0,
                top: 0,
                width: 2880,
                height: 1840,
            },
            16,
        );
        assert!(!physical_rects_overlap(
            group.bubble.bounds,
            group.menu.bounds
        ));
        assert!(!physical_rects_overlap(group.menu.bounds, owner));
        assert_eq!(group.menu.bounds.top, 272);
    }

    #[test]
    fn drag_safe_menu_uses_left_after_right_is_clamped_over_companion() {
        let work_area = PhysicalRect {
            left: 0,
            top: 0,
            width: 800,
            height: 600,
        };
        let drag_safe = expand_physical_rect_within(
            PhysicalRect {
                left: 736,
                top: 510,
                width: 64,
                height: 64,
            },
            12,
            work_area,
        );
        let menu = place_drag_safe_auxiliary_menu(drag_safe, (300, 288), (200, 288), work_area, 8)
            .expect("left-hand placement must fit");
        assert_eq!(menu.placement, AuxiliaryPlacement::Left);
        assert!(!physical_rects_overlap(menu.bounds, drag_safe));
    }

    #[test]
    fn drag_safe_menu_retries_compact_width_after_normal_menu_has_no_safe_slot() {
        let work_area = PhysicalRect {
            left: 0,
            top: 0,
            width: 400,
            height: 300,
        };
        let drag_safe = PhysicalRect {
            left: 96,
            top: 0,
            width: 208,
            height: 300,
        };
        let menu = place_drag_safe_auxiliary_menu(drag_safe, (240, 288), (80, 288), work_area, 8)
            .expect("compact menu must fit in the remaining work-area column");
        assert_eq!(menu.placement, AuxiliaryPlacement::Right);
        assert_eq!(menu.bounds.width, 80);
        assert!(!physical_rects_overlap(menu.bounds, drag_safe));
    }

    #[test]
    fn submenu_avoids_both_the_drag_target_and_parent_menu() {
        let work_area = PhysicalRect {
            left: 0,
            top: 0,
            width: 1000,
            height: 700,
        };
        let drag_safe = PhysicalRect {
            left: 0,
            top: 250,
            width: 88,
            height: 120,
        };
        let menu = place_drag_safe_auxiliary_menu(drag_safe, (300, 288), (200, 288), work_area, 8)
            .expect("primary menu must fit");
        let submenu = place_auxiliary_avoiding(
            menu.bounds,
            (210, 200),
            work_area,
            8,
            &[drag_safe, menu.bounds],
        )
        .expect("submenu must fit");
        assert!(!physical_rects_overlap(submenu.bounds, drag_safe));
        assert!(!physical_rects_overlap(submenu.bounds, menu.bounds));
    }

    #[test]
    fn side_submenu_prefers_right_then_flips_left_and_clamps_y() {
        let work_area = PhysicalRect {
            left: 0,
            top: 0,
            width: 1200,
            height: 700,
        };
        let center_row = PhysicalRect {
            left: 300,
            top: 260,
            width: 240,
            height: 32,
        };
        let right = place_side_submenu(center_row, (280, 140), work_area, 2);
        assert_eq!(right.placement, AuxiliaryPlacement::Right);
        assert_eq!(right.bounds.left, 542);

        let edge_row = PhysicalRect {
            left: 920,
            top: 650,
            width: 240,
            height: 32,
        };
        let left = place_side_submenu(edge_row, (280, 140), work_area, 2);
        assert_eq!(left.placement, AuxiliaryPlacement::Left);
        assert_eq!(left.bounds.left, 638);
        assert_eq!(left.bounds.top, 560);
        assert_eq!(left.bounds.top + left.bounds.height, work_area.height);
    }

    #[test]
    fn side_submenu_stays_visible_when_neither_side_fully_fits() {
        let work_area = PhysicalRect {
            left: 0,
            top: 0,
            width: 500,
            height: 300,
        };
        let row = PhysicalRect {
            left: 170,
            top: 260,
            width: 160,
            height: 32,
        };
        let submenu = place_side_submenu(row, (260, 120), work_area, 2);
        assert!(submenu.bounds.left >= work_area.left);
        assert!(submenu.bounds.left + submenu.bounds.width <= work_area.left + work_area.width);
        assert!(submenu.bounds.top >= work_area.top);
        assert!(submenu.bounds.top + submenu.bounds.height <= work_area.top + work_area.height);
    }

    #[test]
    fn popup_rows_reserve_the_visual_header_without_shifting_actions() {
        assert_eq!(popup_row_from_client_y(0, 48, 42, 8), None);
        assert_eq!(popup_row_from_client_y(47, 48, 42, 8), None);
        assert_eq!(popup_row_from_client_y(48, 48, 42, 8), Some(0));
        assert_eq!(popup_row_from_client_y(89, 48, 42, 8), Some(0));
        assert_eq!(popup_row_from_client_y(90, 48, 42, 8), Some(1));
        assert_eq!(popup_row_from_client_y(384, 48, 42, 8), None);
    }

    #[test]
    fn popup_row_bounds_anchor_each_flyout_to_its_parent_row() {
        let menu = PhysicalRect {
            left: 100,
            top: 200,
            width: 300,
            height: 304,
        };

        assert_eq!(
            popup_row_bounds(menu, 48, 32, 0),
            Some(PhysicalRect {
                left: 100,
                top: 248,
                width: 300,
                height: 32,
            })
        );
        assert_eq!(
            popup_row_bounds(menu, 48, 32, 1),
            Some(PhysicalRect {
                left: 100,
                top: 280,
                width: 300,
                height: 32,
            })
        );
        assert_eq!(
            popup_row_bounds(menu, 48, 32, 2),
            Some(PhysicalRect {
                left: 100,
                top: 312,
                width: 300,
                height: 32,
            })
        );
        assert_eq!(popup_row_bounds(menu, 48, 32, 8), None);
    }

    #[test]
    fn popup_segments_cover_each_size_card_without_overlapping_edges() {
        assert_eq!(popup_segment_from_client_x(16, 16, 216, 5), Some(0));
        assert_eq!(popup_segment_from_client_x(55, 16, 216, 5), Some(0));
        assert_eq!(popup_segment_from_client_x(56, 16, 216, 5), Some(1));
        assert_eq!(popup_segment_from_client_x(215, 16, 216, 5), Some(4));
        assert_eq!(popup_segment_from_client_x(216, 16, 216, 5), None);
        assert_eq!(popup_segment_from_client_x(15, 16, 216, 5), None);
    }

    #[test]
    fn hover_menu_keeps_release_actions_and_excludes_developer_shortcuts() {
        assert_eq!(hover_menu_submenu_mode(0), Some(0));
        assert_eq!(hover_menu_submenu_mode(1), Some(1));
        assert_eq!(hover_menu_submenu_mode(2), Some(2));
        assert_eq!(hover_menu_submenu_mode(3), None);

        assert_eq!(hover_menu_primary_action(3), Some("chat"));
        assert_eq!(hover_menu_primary_action(4), Some("settings"));
        assert_eq!(hover_menu_primary_action(5), Some("change-character"));
        assert_eq!(hover_menu_primary_action(6), Some("hide-to-tray"));
        assert_eq!(hover_menu_primary_action(7), Some("exit"));
        assert_eq!(hover_menu_primary_action(8), None);
    }

    #[test]
    fn hover_menu_localization_changes_copy_without_changing_action_contracts() {
        assert_eq!(normalize_hover_language("th"), "th");
        assert_eq!(normalize_hover_language("th-TH"), "th");
        assert_eq!(normalize_hover_language("en"), "en");
        assert_eq!(normalize_hover_language("ja"), "en");

        assert_eq!(localized_hover_label("th", "Actions"), "ท่าทาง");
        assert_eq!(
            localized_hover_label("th", "Change Character"),
            "เปลี่ยนตัวละคร"
        );
        assert_eq!(localized_hover_label("th", "Mute all"), "ปิดเสียงทั้งหมด");
        assert_eq!(localized_hover_label("en", "Actions"), "Actions");
        assert_eq!(localized_hover_label("th", "Bible"), "Bible");

        // Localization is presentation-only; row/action IDs remain stable.
        assert_eq!(hover_menu_primary_action(5), Some("change-character"));
        assert_eq!(hover_menu_submenu_action(0, 1), Some("wave"));
    }

    #[test]
    fn sound_flyout_emits_runtime_requests_not_mutable_native_state() {
        assert_eq!(hover_menu_submenu_action(2, 0), Some("sound-master-toggle"));
        assert_eq!(hover_menu_submenu_action(2, 1), Some("sound-sfx-toggle"));
        assert_eq!(hover_menu_submenu_action(2, 2), None);
        assert_eq!(hover_menu_submenu_action(3, 0), None);
    }

    #[test]
    fn companion_scale_presets_map_to_the_active_size_segment() {
        assert_eq!(companion_scale_preset_index(0.25), Some(0));
        assert_eq!(companion_scale_preset_index(0.50), Some(1));
        assert_eq!(companion_scale_preset_index(0.75), Some(2));
        assert_eq!(companion_scale_preset_index(1.00), Some(3));
        assert_eq!(companion_scale_preset_index(1.25), Some(4));
        assert_eq!(companion_scale_preset_index(0.33), None);
        assert_eq!(companion_scale_preset_index(f64::NAN), None);
    }

    #[test]
    fn colorref_rgb_encodes_blue_grey_without_swapping_red_and_blue() {
        assert_eq!(colorref_rgb(60, 95, 142), 0x008E_5F3C);
        assert_ne!(colorref_rgb(60, 95, 142), 0x003C_5F8E);
    }

    #[test]
    fn render_host_resize_does_not_mutate_canonical_feet() {
        let monitors = mixed_dpi_fixture();
        let feet = DesktopLogicalPoint {
            x: -960.0,
            y: 1032.0,
        };
        let placement =
            canonical_feet_to_native_placement(feet, (128.0, 128.0), &monitors).unwrap();
        let before = render_host_layout(placement, feet, (0, 0));
        let after = render_host_layout(placement, feet, (8, 12));

        assert_eq!(before.native_bounds, after.native_bounds);
        assert_eq!(before.client_size, (128, 128));
        assert_eq!(after.client_size, (112, 104));
        assert!(render_host_preserves_canonical_feet(before, after));
    }

    #[test]
    fn render_host_insets_are_clamped_inside_native_window() {
        let placement = NativePlacement {
            monitor_id: 1,
            bounds: PhysicalRect {
                left: 10,
                top: 20,
                width: 16,
                height: 12,
            },
        };
        let layout =
            render_host_layout(placement, DesktopLogicalPoint { x: 1.0, y: 2.0 }, (99, 99));
        assert_eq!(layout.client_size, (1, 1));
    }

    #[test]
    fn render_host_adapter_accepts_valid_lifecycle() {
        let token = RenderHostToken(7);
        let mut state = RenderHostLifecycle::Created;
        state = advance_render_host(state, RenderHostLifecycle::Ready, token).unwrap();
        state = advance_render_host(
            state,
            RenderHostLifecycle::Resized {
                width: 256,
                height: 256,
            },
            token,
        )
        .unwrap();
        state = advance_render_host(state, RenderHostLifecycle::Hidden, token).unwrap();
        state = advance_render_host(state, RenderHostLifecycle::Visible, token).unwrap();
        assert_eq!(
            advance_render_host(state, RenderHostLifecycle::Detached, token),
            Some(RenderHostLifecycle::Detached)
        );
    }

    #[test]
    fn render_host_adapter_rejects_invalid_token_and_transition() {
        assert!(!validate_render_host_token(RenderHostToken(0)));
        assert!(advance_render_host(
            RenderHostLifecycle::Created,
            RenderHostLifecycle::Ready,
            RenderHostToken(0)
        )
        .is_none());
        assert!(advance_render_host(
            RenderHostLifecycle::Created,
            RenderHostLifecycle::Hidden,
            RenderHostToken(7)
        )
        .is_none());
        assert!(advance_render_host(
            RenderHostLifecycle::Ready,
            RenderHostLifecycle::Resized {
                width: 0,
                height: 256,
            },
            RenderHostToken(7)
        )
        .is_none());
    }
}
