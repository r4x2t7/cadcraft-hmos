//! Session state behind the Node-API exports: the engine session plus the canvas size.
//!
//! View state lives in the engine itself (`DocState::view`), so pan/zoom are plain engine
//! calls and the renderer reads back the same view the command line's `ZOOM`/`PAN` produce.

use cadcraft_engine::geom::Vec2;
use cadcraft_engine::{Input, Session, View as EngineView};

pub struct App {
    pub session: Session,
    /// Canvas size in device pixels.
    pub width: u32,
    pub height: u32,
}

impl App {
    pub fn new() -> Self {
        let mut session = Session::new();
        session.viewport_px = (1200.0, 800.0);
        App { session, width: 1200, height: 800 }
    }

    pub fn resize(&mut self, w: f64, h: f64) {
        // Device pixels, bounded like the rasteriser (16..=16384).
        let clamp = |v: f64| v.round().clamp(16.0, 16384.0);
        self.width = clamp(w) as u32;
        self.height = clamp(h) as u32;
        self.session.viewport_px = (f64::from(self.width), f64::from(self.height));
    }

    /// The pixels-per-world-unit of the current engine view at the current canvas width.
    fn scale(&self) -> f64 {
        let view = self.engine_view();
        f64::from(self.width) / view.height.max(1e-9)
    }

    fn engine_view(&self) -> EngineView {
        self.session.state().map(|st| st.view()).unwrap_or_default()
    }

    /// Device px on the canvas → world coordinates (y up, centre of the view fixed).
    pub fn to_world(&self, x: f64, y: f64) -> Vec2 {
        let view = self.engine_view();
        let scale = self.scale();
        let wx = view.center.x + (x - f64::from(self.width) / 2.0) / scale;
        let wy = view.center.y + (f64::from(self.height) / 2.0 - y) / scale;
        Vec2::new(wx, wy)
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

    /// Prompt, keyword options, log tail and the drawing epoch (the shell polls `cadState`).
    pub fn state_json(&self) -> Result<String, String> {
        let view = self.engine_view();
        let prompt = self.session.current_prompt().map(|p| {
            serde_json::json!({ "message": p.message, "keywords": p.keywords })
        });
        let log: Vec<String> = self.session.log.iter().rev().take(30).rev().cloned().collect();
        let state = serde_json::json!({
            "ok": true,
            "epoch": self.session.doc_epoch,
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
        // During a prompt a click is a point input (or a pick, the prompt machine decides);
        // otherwise it picks objects / starts a window selection, exactly like the desktop.
        if self.session.current_prompt().is_some() {
            self.session.input(Input::Point(w)).map_err(|e| format!("{e}"))?;
        } else {
            self.session.idle_click(w, shift).map_err(|e| format!("{e}"))?;
        }
        Ok(self.state_json()?)
    }

    pub fn move_cursor(&mut self, x: f64, y: f64) {
        self.session.cursor = self.to_world(x, y);
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
        let center = Vec2::new(
            view.center.x - dx_px / scale,
            view.center.y + dy_px / scale,
        );
        if let Ok(st) = self.session.state_mut() {
            st.set_view_quiet(EngineView { center, height: view.height });
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
