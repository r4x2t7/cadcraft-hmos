//! CPU-rasterised canvas frames: engine display list → tiny-skia RGBA, like the web and
//! plot paths. The shell blits the buffer into a PixelMap each redraw.
//!
//! Kept entirely inside this crate on purpose: upstream `crates/render` evolves fast, and
//! anything we need from it that does not exist (viewport culling beyond hatches, parallel
//! strips) is upstream-PR material, not a local patch. `d.model.iter()` +
//! `doc::extents::entity_bounds` + `pipeline::build_entities` are public API, so the
//! culling here is a pure caller-side filter.

use cadcraft_engine::geom::{Bounds2, Vec2};

use crate::app::App;

/// Render the current view INTO a caller-provided buffer (no per-frame allocation: under
/// host memory pressure, napi_create_arraybuffer and image.createPixelMap stall the JS
/// thread — one reusable buffer avoids that entirely). Writes straight RGBA_8888 (the
/// background is opaque), row-major top-left origin, no padding. Returns the byte count
/// written, or 0 when nothing is ready (view unset, absurd size).
pub fn frame_into(app: &mut App, out: &mut [u8]) -> usize {
    let started = std::time::Instant::now();
    let Ok(st) = app.session.state() else { return 0 };
    let view = st.view();
    let (center, height) = (view.center, view.height);
    let (w, h) = (app.width, app.height);
    // Pixels per world unit must be derived from the *canvas height*: view.height is a
    // world-space height, and raster::View::world_bounds()/to_screen() both use
    // height / scale. Using canvas width here doubled the scale, cropped the lower
    // half of the drawing and left a blank band under the geometry.
    let scale = f64::from(h) / height.max(1e-9);
    if !(scale.is_finite() && scale > 0.0) {
        return 0;
    }
    let raster_view = cadcraft_render::raster::View {
        center,
        scale,
        width: w,
        height: h,
    };
    let Ok(d) = app.session.doc() else { return 0 };
    let space = app.session.space();

    // ---- display list: viewport culling + build -------------------------------
    let build_started = std::time::Instant::now();
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
    // Entities whose bounds miss the view (2% slack for hairline extents) never enter the
    // display list. Skipped when the view already covers the drawing: the filter would only
    // pay for itself.
    let vb = raster_view.world_bounds();
    let slack = (vb.width() + vb.height()) * 0.02;
    let culled = Bounds2::new(vb.min - Vec2::new(slack, slack), vb.max + Vec2::new(slack, slack));
    let total = d.model.len();
    let ext = d.extents(&space);
    let covers_drawing = ext.is_empty()
        || (culled.min.x <= ext.min.x && culled.min.y <= ext.min.y
            && culled.max.x >= ext.max.x && culled.max.y >= ext.max.y);
    // Rubber-band preview: while a command prompts, its preview entities (the line
    // following the cursor, drag ghosts, …) render with the frame, exactly like the
    // desktop canvas. The engine tracks the cursor via cadMove.
    let preview = app.session.preview(app.session.cursor);
    let list = if covers_drawing {
        app.last_visible = total;
        cadcraft_render::build_entities(
            d,
            d.model.iter().map(|e| e.as_ref()).chain(preview.iter()),
            &opts,
        )
    } else {
        let visible: Vec<&cadcraft_doc::Entity> = d
            .model
            .iter()
            .filter(|e| cadcraft_doc::entity_bounds(d, e, 0).intersects(&culled))
            .map(|e| e.as_ref())
            .chain(preview.iter())
            .collect();
        app.last_visible = visible.len();
        cadcraft_render::build_entities(d, visible, &opts)
    };
    drop(d);
    drop(preview);
    let build_ms = build_started.elapsed().as_secs_f64() * 1000.0;

    // ---- raster ----------------------------------------------------------------
    let render_started = std::time::Instant::now();
    let need = (raster_view.width as usize) * (raster_view.height as usize) * 4;
    if out.len() < need {
        app.last_frame_ms = started.elapsed().as_secs_f64() * 1000.0;
        return 0;
    }
    match cadcraft_render::raster::render(
        &list,
        &raster_view,
        &cadcraft_render::raster::RasterOptions::default(),
    ) {
        Some(pm) => {
            // Canvas putImageData takes straight RGBA (Web ImageData semantics); the
            // background is opaque, so premultiplied == straight. Fill in place.
            let data = pm.data();
            out[..data.len()].copy_from_slice(data);
            app.last_build_ms = build_ms;
            app.last_raster_ms = render_started.elapsed().as_secs_f64() * 1000.0;
            app.last_frame_ms = started.elapsed().as_secs_f64() * 1000.0;
            data.len()
        }
        None => {
            app.last_frame_ms = started.elapsed().as_secs_f64() * 1000.0;
            0
        }
    }
}
