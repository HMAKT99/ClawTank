//! Deterministic test image used until live capture lands (Phase 2).
//!
//! Top three quarters: eight vertical colour bars. Bottom quarter: a horizontal grey ramp.
//! [`expected_rgb`] is the single source of truth, so tests can check decoded client pixels.

/// Bar colours, left to right (RGB).
pub const BARS: [(u8, u8, u8); 8] = [
    (255, 255, 255),
    (255, 255, 0),
    (0, 255, 255),
    (0, 255, 0),
    (255, 0, 255),
    (255, 0, 0),
    (0, 0, 255),
    (0, 0, 0),
];

/// RGB colour of pixel (`x`, `y`) in a `width`×`height` pattern.
pub fn expected_rgb(x: u32, y: u32, width: u32, height: u32) -> (u8, u8, u8) {
    if y < height * 3 / 4 {
        let bar = (x * BARS.len() as u32 / width) as usize;
        BARS[bar.min(BARS.len() - 1)]
    } else {
        let v = u8::try_from(x * 255 / width.saturating_sub(1).max(1)).unwrap_or(255);
        (v, v, v)
    }
}

/// Renders the pattern as tightly packed BGRA (`PixelFormat::BgrA32`), stride = width × 4.
pub fn render_bgra(width: u16, height: u16) -> Vec<u8> {
    let (w, h) = (u32::from(width), u32::from(height));
    let mut out = Vec::with_capacity(w as usize * h as usize * 4);
    for y in 0..h {
        for x in 0..w {
            let (r, g, b) = expected_rgb(x, y, w, h);
            out.extend_from_slice(&[b, g, r, 0xff]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_matches_expected() {
        let (w, h) = (64u16, 32u16);
        let px = render_bgra(w, h);
        assert_eq!(px.len(), 64 * 32 * 4);
        for (x, y) in [(0, 0), (9, 5), (63, 0), (0, 31), (63, 31), (32, 24)] {
            let i = (y * 64 + x) as usize * 4;
            let (r, g, b) = expected_rgb(x, y, 64, 32);
            assert_eq!(&px[i..i + 4], &[b, g, r, 0xff], "pixel ({x},{y})");
        }
    }

    #[test]
    fn ramp_spans_black_to_white() {
        assert_eq!(expected_rgb(0, 99, 100, 100), (0, 0, 0));
        assert_eq!(expected_rgb(99, 99, 100, 100), (255, 255, 255));
    }
}
