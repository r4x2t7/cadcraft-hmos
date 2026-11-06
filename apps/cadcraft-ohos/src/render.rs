//! CPU-rasterised canvas frames: engine display list → tiny-skia RGBA, like the web and
//! plot paths. The shell blits the buffer into a PixelMap each redraw.

use crate::app::App;

/// Render the current view. Returns premultiplied RGBA_8888 bytes (the background is
/// opaque, so premultiplied equals straight), row-major top-left origin, no padding.
pub fn frame(app: &mut App) -> Vec<u8> {
    let started = std::time::Instant::now();
    let Ok(st) = app.session.state() else { return Vec::new() };
    let view = st.view();
    let (center, height) = (view.center, view.height);
    let (w, h) = (app.width, app.height);
    let scale = f64::from(w) / height.max(1e-9);
    if !(scale.is_finite() && scale > 0.0) {
        return Vec::new();
    }
    let raster_view = cadcraft_render::raster::View {
        center,
        scale,
        width: w,
        height: h,
    };

    let Ok(d) = app.session.doc() else { return Vec::new() };
    let space = app.session.space();
    let opts = cadcraft_render::Options {
        // About half a pixel of chord tolerance at the current zoom, like the desktop canvas.
        tolerance: 0.5 / scale,
        min_dash: 2.0 / scale,
        text: true,
        linetypes: true,
        fill: true,
        lineweights: false,
        view_height: height,
        plot_style_table: None,
        view: Some(raster_view.world_bounds()),
        transparency: false,
        skip_viewport: None,
        cancel: None,
    };
    let list = cadcraft_render::build(d, &space, &opts);

    match cadcraft_render::raster::render(&list, &raster_view, &cadcraft_render::raster::RasterOptions::default()) {
        Some(pm) => {
            let mut bytes = pm.data().to_vec();
            // The shell hands the buffer to image.createPixelMap, whose source pixels are
            // read as BGRA_8888 by default (SDK 26 ignores an explicit RGBA srcPixelFormat),
            // so swap R/B once here: premultiplied RGBA → premultiplied BGRA.
            for px in bytes.chunks_exact_mut(4) {
                px.swap(0, 2);
            }
            app.last_frame_ms = started.elapsed().as_secs_f64() * 1000.0;
            bytes
        }
        None => {
            app.last_frame_ms = started.elapsed().as_secs_f64() * 1000.0;
            Vec::new()
        }
    }
}
