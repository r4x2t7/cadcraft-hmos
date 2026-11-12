//! Session state behind the Node-API exports: the engine session plus the canvas size.
//!
//! View state lives in the engine itself (`DocState::view`), so pan/zoom are plain engine
//! calls and the renderer reads back the same view the command line's `ZOOM`/`PAN` produce.

use cadcraft_engine::geom::{Bounds2, Vec2};
use cadcraft_engine::{Input, Session, View as EngineView};

pub struct App {
    pub session: Session,
    /// Canvas size in device pixels.
    pub width: u32,
    pub height: u32,
    /// Wall time of the last `frame()` (build + raster), in ms — shown in the shell's
    /// status bar and the same number to read on a cloud real device later.
    pub last_frame_ms: f64,
    /// Split of the last frame: display-list build and tiny-skia raster.
    pub last_build_ms: f64,
    pub last_raster_ms: f64,
    /// Entities that passed viewport culling (of `model.len()`), last frame.
    pub last_visible: usize,
    /// Snap marker (world xy + label) from the last cursor move, for the shell to draw.
    pub last_snap: Option<(f64, f64, &'static str)>,
}

impl App {
    pub fn new() -> Self {
        let mut session = Session::new();
        session.viewport_px = (1200.0, 800.0);
        App {
            session,
            width: 1200,
            height: 800,
            last_frame_ms: 0.0,
            last_build_ms: 0.0,
            last_raster_ms: 0.0,
            last_visible: 0,
            last_snap: None,
        }
    }

    pub fn resize(&mut self, w: f64, h: f64) {
        // Device pixels, bounded like the rasteriser (16..=16384).
        let clamp = |v: f64| v.round().clamp(16.0, 16384.0);
        self.width = clamp(w) as u32;
        self.height = clamp(h) as u32;
        self.session.viewport_px = (f64::from(self.width), f64::from(self.height));
    }

    /// The pixels-per-world-unit of the current engine view. The session view's `height` is
    /// the world units spanning the viewport HEIGHT, so the scale maps by canvas height —
    /// the same way `render.rs` builds its raster view (a width-based scale doubles the
    /// factor on a 16:9 canvas and every click lands far from the cursor).
    fn scale(&self) -> f64 {
        let view = self.engine_view();
        f64::from(self.height) / view.height.max(1e-9)
    }

    fn engine_view(&self) -> EngineView {
        self.session.state().map(|st| st.view()).unwrap_or_default()
    }

    /// Device px on the canvas → world coordinates (y up, centre of the view fixed). A view
    /// twist (DVIEW/ViewCube, upstream v0.20) turns the drawing on screen: the screen offset
    /// from the centre is un-turned before the world offset is added.
    pub fn to_world(&self, x: f64, y: f64) -> Vec2 {
        let view = self.engine_view();
        let scale = self.scale();
        let d = Vec2::new(
            (x - f64::from(self.width) / 2.0) / scale,
            (f64::from(self.height) / 2.0 - y) / scale,
        );
        let d = if view.twist == 0.0 { d } else { d.rotate(-view.twist) };
        view.center + d
    }

    /// The JSON reply every interaction returns: `cadState` plus any extra field, so the
    /// shell can update its command line and history after each call.
    fn reply(&self, result: serde_json::Value) -> String {
        let mut state: serde_json::Value =
            serde_json::from_str(&self.state_json().unwrap_or_default())
                .unwrap_or(serde_json::json!({ "ok": true }));
        if let Some(obj) = state.as_object_mut() {
            obj.insert("result".into(), result);
        }
        state.to_string()
    }

    /// The engine menu tree, flattened per top menu (`Draw`, `Modify`, …); depth-3 paths
    /// become `Group › Item` labels. The shell builds its menubar from this.
    pub fn menus_json() -> Result<String, String> {
        use cadcraft_engine::cmd::command_specs;
        let mut root: Vec<serde_json::Value> = Vec::new();
        for spec in command_specs() {
            if spec.menu.len() < 2 {
                continue;
            }
            let top = spec.menu[0];
            let idx = match root.iter().position(|n| n["title"] == top) {
                Some(i) => i,
                None => {
                    root.push(serde_json::json!({ "title": top, "items": [] }));
                    root.len() - 1
                }
            };
            let label = if spec.menu.len() > 2 {
                format!("{} › {}", spec.menu[1], spec.menu[2..].join(" › "))
            } else {
                spec.menu[1].to_string()
            };
            let mut item = serde_json::json!({ "label": label, "id": spec.id });
            if let Some(k) = spec.shortcut {
                item["key"] = serde_json::json!(k);
            }
            if let Some(items) = root[idx]["items"].as_array_mut() {
                items.push(item);
            }
        }
        serde_json::to_string(&root).map_err(|e| format!("menus: {e}"))
    }

    /// Start a grip edit on hot grips [[handle, index], …] (engine `start_grip_edit`).
    /// The whole edit — moves, copies, mode cycling — is one undo step.
    pub fn grip_edit(&mut self, grips: &[(u64, usize)]) -> Result<String, String> {
        let hs: Vec<(cadcraft_doc::Handle, usize)> = grips
            .iter()
            .map(|(h, i)| (cadcraft_doc::Handle(*h), *i))
            .collect();
        self.session
            .start_grip_edit(&hs)
            .map_err(|e| format!("{e}"))?;
        self.state_json()
    }

    /// Zoom to a window (two corner points in device px).
    pub fn zoom_window(&mut self, x1: f64, y1: f64, x2: f64, y2: f64) -> Result<String, String> {
        let w1 = self.to_world(x1, y1);
        let w2 = self.to_world(x2, y2);
        let center = Vec2::new((w1.x + w2.x) / 2.0, (w1.y + w2.y) / 2.0);
        let aspect = f64::from(self.width) / f64::from(self.height).max(1.0);
        // Use the larger dimension for the view height to fit the window; a twist keeps
        // turning (the window was picked in the turned screen frame already).
        let hh = ((w2.y - w1.y).abs().max((w2.x - w1.x).abs() / aspect.max(0.01)).max(1e-9)) * 1.05;
        let view = self.engine_view();
        if let Ok(st) = self.session.state_mut() {
            st.set_view_quiet(cadcraft_engine::View { center, height: hh, twist: view.twist });
        }
        self.state_json()
    }

    /// Switch the active document tab (the engine exposes `docs`/`active` directly).
    pub fn doc_switch(&mut self, index: usize) -> Result<String, String> {
        if index < self.session.docs.len() {
            self.session.active = index;
        }
        self.state_json()
    }

    /// Prompt, keyword options, log tail and the drawing epoch (the shell polls `cadState`).
    pub fn state_json(&self) -> Result<String, String> {        let view = self.engine_view();
        let prompt = self.session.current_prompt().map(|p| {
            serde_json::json!({ "message": p.message, "keywords": p.keywords })
        });
        let log: Vec<String> = self.session.log.iter().rev().take(30).rev().cloned().collect();
        let (layers, current_layer) = match self.session.doc() {
            Ok(d) => (
                d.layers
                    .iter()
                    .map(|l| {
                        let hex = format!(
                            "#{:06X}",
                            l.color
                                .resolve(
                                    cadcraft_color::Color::Index(7),
                                    cadcraft_color::Color::Index(7)
                                )
                                .to_u32()
                        );
                        serde_json::json!({
                            "name": l.name, "color": hex,
                            "on": l.on, "frozen": l.frozen, "locked": l.locked,
                        })
                    })
                    .collect::<Vec<_>>(),
                self.session.current_common().layer.clone(),
            ),
            Err(_) => (Vec::new(), String::new()),
        };
        let handles = self.session.selection();
        let selection: Vec<serde_json::Value> = if let Ok(d) = self.session.doc() {
            handles
                .iter()
                .filter_map(|h| d.model.get(*h))
                .take(200)
                .map(|e| {
                    serde_json::json!({
                        "handle": e.handle.0,
                        "kind": format!("{:?}", e.kind),
                        "layer": e.common.layer,
                        "color": format!("{:?}", e.common.color),
                    })
                })
                .collect()
        } else {
            Vec::new()
        };
        // Space / layouts / docs / modes / pending selection window, for the shell's tabs
        // and status bar.
        let space = self.session.space();
        let space_name = match space {
            cadcraft_doc::Space::Model => "模型".to_string(),
            cadcraft_doc::Space::Paper(ref n) => format!("布局 {n}"),
        };
        let layouts: Vec<String> = self
            .session
            .doc()
            .map(|d| d.layouts.iter().map(|l| l.name.clone()).collect())
            .unwrap_or_default();
        let docs: Vec<String> = self.session.docs.iter().map(|st| st.title.clone()).collect();
        let ortho = matches!(
            cadcraft_engine::sysvars::get(&self.session, "ORTHOMODE"),
            Some(serde_json::Value::Number(ref n)) if n.as_i64().unwrap_or(0) != 0
        );
        let osnap = matches!(
            cadcraft_engine::sysvars::get(&self.session, "OSMODE"),
            Some(serde_json::Value::Number(ref n)) if n.as_i64().unwrap_or(0) != 0
        );
        let window = self
            .session
            .pending_window
            .map(|w| serde_json::json!([w.corner.x, w.corner.y]));
        // Grip points of the selection (editable defining points, world coords) for the
        // shell's grip squares and grip-edit targeting.
        let grips: Vec<serde_json::Value> = if let Ok(d) = self.session.doc() {
            handles
                .iter()
                .filter_map(|h| d.model.get(*h))
                .flat_map(|e| {
                    e.kind
                        .grips()
                        .into_iter()
                        .enumerate()
                        .map(move |(i, g)| {
                            serde_json::json!({
                                "handle": e.handle.0,
                                "index": i,
                                "x": g.x,
                                "y": g.y,
                            })
                        })
                })
                .take(400)
                .collect()
        } else {
            Vec::new()
        };
        let state = serde_json::json!({
            "ok": true,
            "epoch": self.session.doc_epoch,
            "frameMs": self.last_frame_ms,
            "buildMs": self.last_build_ms,
            "rasterMs": self.last_raster_ms,
            "visible": self.last_visible,
            "total": self.session.doc().map(|d| d.model.len()).unwrap_or(0),
            "layers": layers,
            "currentLayer": current_layer,
            "selection": selection,
            "space": space_name,
            "layouts": layouts,
            "docs": docs,
            "doc": self.session.active,
            "ortho": ortho,
            "osnap": osnap,
            "window": window,
            "snapMarker": self.last_snap.map(|(x, y, name)| {
                serde_json::json!([x, y, name])
            }),
            "grips": grips,
            "prompting": prompt.is_some(),
            "prompt": prompt,
            "view": { "center": [view.center.x, view.center.y], "height": view.height },
            "canvas": { "width": self.width, "height": self.height },
            "log": log,
        });
        serde_json::to_string(&state).map_err(|e| format!("state: {e}"))
    }

    pub fn execute(&mut self, command: &str, params: serde_json::Value) -> Result<String, String> {
        match self.session.execute(command, &params) {
            Ok(result) => Ok(self.reply(serde_json::json!({ "result": result }))),
            Err(e) => Err(format!("{e}")),
        }
    }

    pub fn cmdline(&mut self, text: &str) -> Result<String, String> {
        self.session.cmdline(text).map_err(|e| format!("{e}"))?;
        Ok(self.state_json()?)
    }

    /// Start an interactive command by its id (as `app.start(id)` does on the desktop):
    /// toolbar buttons run the same prompt sequence the command line would.
    pub fn start(&mut self, name: &str) -> Result<String, String> {
        self.session.start(name).map_err(|e| format!("{e}"))?;
        Ok(self.state_json()?)
    }

    pub fn input(&mut self, input: Input) -> Result<String, String> {
        self.session.input(input).map_err(|e| format!("{e}"))?;
        Ok(self.state_json()?)
    }

    pub fn click(&mut self, x: f64, y: f64, shift: bool, ctrl: bool) -> Result<String, String> {
        self.session.ctrl_down = ctrl;
        let w = self.to_world(x, y);
        // Object snap: compute the nearest snap point for this click.
        let px = self.session.pixel_size();
        let aperture = 10.0 * px;
        let prompt = self.session.current_prompt();
        let q = cadcraft_engine::snap::tracking::CursorQuery {
            base: prompt.as_ref().and_then(|pr| pr.base),
            deferred: false,
            corner: false,
            aperture,
            tol: px * 4.0,
            shift: false,
            now: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0.0, |d| d.as_secs_f64()),
        };
        let snap = self.session.snap_cursor(w, &q);
        // During a prompt: snapped input if available, else a plain point.
        // Idle: snapped click or plain idle_click.
        if self.session.current_prompt().is_some() {
            match snap.snap {
                Some(hit) => self.session.input_snapped(hit).map_err(|e| format!("{e}"))?,
                None => self.session.input(Input::Point(w)).map_err(|e| format!("{e}"))?,
            };
        } else {
            self.session.idle_click(w, shift).map_err(|e| format!("{e}"))?;
        }
        Ok(self.state_json()?)
    }

    pub fn move_cursor(&mut self, x: f64, y: f64) {
        let w = self.to_world(x, y);
        self.session.cursor = w;
        // Object snap: compute the nearest snap point within the aperture.
        let px = self.session.pixel_size();
        let aperture = 10.0 * px;
        let prompt = self.session.current_prompt();
        let q = cadcraft_engine::snap::tracking::CursorQuery {
            base: prompt.as_ref().and_then(|pr| pr.base),
            deferred: false,
            corner: false,
            aperture,
            tol: px * 4.0,
            shift: false,
            now: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0.0, |d| d.as_secs_f64()),
        };
        let snap = self.session.snap_cursor(w, &q);
        self.last_snap = snap.snap.as_ref().map(|h| (h.point.x, h.point.y, h.name));
    }

    pub fn zoom(&mut self, factor: f64, x: f64, y: f64) -> Result<String, String> {
        let about = self.to_world(x, y);
        self.session.zoom_about(factor, about).map_err(|e| format!("{e}"))?;
        Ok(self.state_json()?)
    }

    pub fn pan(&mut self, dx_px: f64, dy_px: f64) {
        let scale = self.scale();
        if scale <= 0.0 {
            return;
        }
        let view = self.engine_view();
        let d = Vec2::new(-dx_px / scale, dy_px / scale);
        let d = if view.twist == 0.0 { d } else { d.rotate(-view.twist) };
        if let Ok(st) = self.session.state_mut() {
            st.set_view_quiet(EngineView { center: view.center + d, height: view.height, twist: view.twist });
        }
    }

    pub fn zoom_extents(&mut self) -> Result<String, String> {
        self.session.zoom_extents().map_err(|e| format!("{e}"))?;
        Ok(self.state_json()?)
    }

    pub fn open_dxf(&mut self, name: &str, bytes: &[u8]) -> Result<String, String> {
        let drawing = cadcraft_io::read_dxf(bytes).map_err(|e| format!("{e}"))?;
        self.session.open_drawing(drawing, name, None);
        let _ = self.session.zoom_extents();
        Ok(self.state_json()?)
    }

    pub fn save_dxf(&self) -> Result<String, String> {
        let d = self.session.doc().map_err(|e| format!("{e}"))?;
        Ok(cadcraft_io::write_dxf(d))
    }
}
