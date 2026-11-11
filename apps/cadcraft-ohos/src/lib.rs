//! CADCraft on HarmonyOS/OpenHarmony: the engine behind the ArkUI shell.
//!
//! The desktop app is eframe/egui on winit/wgpu; winit has no OHOS backend
//! (rust-windowing/winit#4081), so this port keeps the architecture the repo already
//! prescribes — "the UI crate is swappable, everything is a command" — and swaps in an
//! ArkUI front end. This Node-API module drives `cadcraft-engine` directly and hands the
//! UI CPU-rasterised frames (`cadcraft-render` → tiny-skia), exactly like the web/plot
//! paths. All coordinate arguments are device pixels relative to the canvas, origin at the
//! top left.
//!
//! Exports (all JSON returns are strings; errors are `{"ok":false,"error":...}`):
//! - `cadInit() -> json` — a fresh untitled drawing, zoomed to extents.
//! - `cadResize(w, h)` — canvas size in device px (also sets the engine's pick apertures).
//! - `cadExecute(command, paramsJson) -> json` — the JSON form of any command.
//! - `cadCmdline(text) -> json` — type at the command line like a user.
//! - `cadStart(commandId) -> json` — start an interactive command (toolbar buttons).
//! - `cadEnter() / cadCancel() -> json` — Enter / Esc.
//! - `cadClick(x, y, shift, ctrl) -> json` — click-to-pick or a point for the prompt.
//! - `cadMove(x, y)` — cursor tracking (direct distance entry, previews).
//! - `cadZoom(factor, x, y) / cadPan(dx, dy) / cadZoomExtents() -> json`.
//! - `cadOpenDxf(name, arrayBuffer) -> json` — parse DXF bytes into a new document.
//! - `cadSaveDxf() -> string` — the drawing as DXF text.
//! - `cadState() -> json` — prompt, keywords, log tail, epoch (the UI polls this).
//! - `cadFrame() -> ArrayBuffer` — RGBA_8888 (premultiplied, opaque background) pixels.

// NOTE: the ohos triples set target_os = "linux" and target_env = "ohos" — gate on
// target_env (rustc --target aarch64-unknown-linux-ohos --print cfg).
#![cfg(target_env = "ohos")]
// Every export below is itself the safety boundary for loader-provided Node-API handles;
// the `unsafe` bodies each only touch `ffi` wrappers documented as such.
#![allow(unsafe_op_in_unsafe_fn)]
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::todo, clippy::unimplemented)]

mod app;
mod ffi;
mod render;

use std::sync::Mutex;

use crate::app::App;

/// The Node-API module name: ArkTS loads it as `import cad from 'libcadcraft_ohos.so'`.
const MODULE_NAME: &[u8] = b"cadcraft_ohos\0";

static APP: Mutex<Option<App>> = Mutex::new(None);

/// Lock the app, absorbing poisoning (a panic inside one call must not brick the session;
/// the repo's catch_unwind guards live in the engine and the UI crate).
fn with_app<T>(f: impl FnOnce(&mut App) -> T) -> Option<T> {
    let mut guard = match APP.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    guard.as_mut().map(f)
}

/// A JSON-string reply from an app call: `Ok` → `{"ok":true,...}`, `Err` → error reply,
/// no session → error reply. Keeps every export's shape identical.
fn js_result(env: ffi::Env, result: Option<Result<String, String>>) -> ffi::Value {
    match result {
        Some(Ok(state)) => ffi::js_string(env, &state),
        Some(Err(msg)) => ffi::js_error(env, &msg),
        None => ffi::js_error(env, "not initialised"),
    }
}

// ---------------- Node-API registration ----------------

static MODULE: ffi::NapiModule = ffi::NapiModule {
    nm_version: 1,
    nm_flags: 0,
    nm_filename: std::ptr::null(),
    nm_register_func: Some(init),
    nm_modname: MODULE_NAME.as_ptr() as *const std::ffi::c_char,
    nm_priv: std::ptr::null(),
    reserved: [std::ptr::null_mut(); 4],
};

#[used]
#[unsafe(link_section = ".init_array")]
static REGISTER_MODULE: unsafe extern "C" fn() = {
    unsafe extern "C" fn register() {
        ffi::napi_module_register(&MODULE);
    }
    register
};

unsafe extern "C" fn init(env: ffi::Env, exports: ffi::Value) -> ffi::Value {
    let pairs: Vec<(&str, ffi::NapiCallback)> = vec![
        ("cadInit", Some(cad_init)),
        ("cadMenus", Some(cad_menus)),
        ("cadResize", Some(cad_resize)),
        ("cadExecute", Some(cad_execute)),
        ("cadCmdline", Some(cad_cmdline)),
        ("cadStart", Some(cad_start)),
        ("cadEnter", Some(cad_enter)),
        ("cadCancel", Some(cad_cancel)),
        ("cadClick", Some(cad_click)),
        ("cadMove", Some(cad_move)),
        ("cadZoom", Some(cad_zoom)),
        ("cadPan", Some(cad_pan)),
        ("cadZoomExtents", Some(cad_zoom_extents)),
        ("cadOpenDxf", Some(cad_open_dxf)),
        ("cadSaveDxf", Some(cad_save_dxf)),
        ("cadState", Some(cad_state)),
        ("cadDocSwitch", Some(cad_doc_switch)),
        ("cadGripEdit", Some(cad_grip_edit)),
        ("cadZoomWindow", Some(cad_zoom_window)),
        ("cadFrameInto", Some(cad_frame)),
    ];
    let props: Vec<(std::ffi::CString, ffi::PropertyDescriptor)> =
        pairs.into_iter().map(|(name, cb)| ffi::prop(name, cb)).collect();
    let descriptors: Vec<ffi::PropertyDescriptor> = props
        .iter()
        .map(|(_, d)| ffi::PropertyDescriptor {
            utf8name: d.utf8name,
            name: d.name,
            method: d.method,
            getter: d.getter,
            setter: d.setter,
            value: d.value,
            attributes: d.attributes,
            data: d.data,
        })
        .collect();
    // SAFETY: `env`/`exports` are the loader-provided Node-API handles; the descriptors
    // borrow the CStrings kept alive in `props` for the duration of the call.
    let status = unsafe {
        ffi::napi_define_properties(env, exports, descriptors.len(), descriptors.as_ptr())
    };
    if status != 0 {
        // The shell reports a black screen; make the failure loud in the ArkTS console.
        let msg = b"cadcraft-ohos: napi_define_properties failed\0";
        unsafe {
            ffi::napi_throw_error(env, std::ptr::null(), msg.as_ptr() as *const std::ffi::c_char);
        }
    }
    exports
}

// ---------------- exports ----------------

unsafe extern "C" fn cad_init(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let _ = ffi::args(env, info);
    {
        let mut guard = match APP.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        let mut app = App::new();
        let _ = app.session.zoom_extents();
        *guard = Some(app);
    }
    ffi::js_ok(env, serde_json::json!({ "version": cadcraft_engine::build_version() }))
}

unsafe extern "C" fn cad_menus(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let _ = ffi::args(env, info);
    match app::App::menus_json() {
        Ok(tree) => ffi::js_string(env, &tree),
        Err(msg) => ffi::js_error(env, &msg),
    }
}

unsafe extern "C" fn cad_resize(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let num = |i: usize| a.get(i).copied().and_then(|v| ffi::arg_f64(env, v));
    if let (Some(w), Some(h)) = (num(0), num(1)) {
        with_app(|app| app.resize(w, h));
    }
    ffi::js_undefined(env)
}

unsafe extern "C" fn cad_execute(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let command = a.first().copied().and_then(|v| ffi::arg_string(env, v));
    let params_json = a.get(1).copied().and_then(|v| ffi::arg_string(env, v));
    let Some(command) = command else { return ffi::js_error(env, "cadExecute(command, paramsJson)") };
    let params: serde_json::Value = match params_json.as_deref() {
        Some(s) if !s.trim().is_empty() => serde_json::from_str(s).unwrap_or(serde_json::Value::Null),
        _ => serde_json::Value::Null,
    };
    js_result(env, with_app(|app| app.execute(&command, params)))
}

unsafe extern "C" fn cad_cmdline(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let text = a.first().copied().and_then(|v| ffi::arg_string(env, v));
    match text {
        Some(text) => js_result(env, with_app(|app| app.cmdline(&text))),
        None => ffi::js_error(env, "cadCmdline(text)"),
    }
}

unsafe extern "C" fn cad_start(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let name = a.first().copied().and_then(|v| ffi::arg_string(env, v));
    match name {
        Some(name) => js_result(env, with_app(|app| app.start(&name))),
        None => ffi::js_error(env, "cadStart(commandId)"),
    }
}

unsafe extern "C" fn cad_enter(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let _ = ffi::args(env, info);
    js_result(env, with_app(|app| app.input(cadcraft_engine::Input::Enter)))
}

unsafe extern "C" fn cad_cancel(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let _ = ffi::args(env, info);
    js_result(env, with_app(|app| app.input(cadcraft_engine::Input::Cancel)))
}

unsafe extern "C" fn cad_click(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let num = |i: usize| a.get(i).copied().and_then(|v| ffi::arg_f64(env, v));
    let (x, y) = (num(0), num(1));
    let shift = num(2).unwrap_or(0.0) != 0.0;
    let ctrl = num(3).unwrap_or(0.0) != 0.0;
    match (x, y) {
        (Some(x), Some(y)) => js_result(env, with_app(|app| app.click(x, y, shift, ctrl))),
        _ => ffi::js_error(env, "cadClick(x, y, shift, ctrl)"),
    }
}

unsafe extern "C" fn cad_move(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let num = |i: usize| a.get(i).copied().and_then(|v| ffi::arg_f64(env, v));
    if let (Some(x), Some(y)) = (num(0), num(1)) {
        with_app(|app| app.move_cursor(x, y));
    }
    ffi::js_undefined(env)
}

unsafe extern "C" fn cad_zoom(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let num = |i: usize| a.get(i).copied().and_then(|v| ffi::arg_f64(env, v));
    match (num(0), num(1), num(2)) {
        (Some(factor), Some(x), Some(y)) => js_result(env, with_app(|app| app.zoom(factor, x, y))),
        _ => ffi::js_error(env, "cadZoom(factor, x, y)"),
    }
}

unsafe extern "C" fn cad_pan(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let num = |i: usize| a.get(i).copied().and_then(|v| ffi::arg_f64(env, v));
    match (num(0), num(1)) {
        (Some(dx), Some(dy)) => {
            with_app(|app| app.pan(dx, dy));
            ffi::js_undefined(env)
        }
        _ => ffi::js_error(env, "cadPan(dx, dy)"),
    }
}

unsafe extern "C" fn cad_zoom_extents(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let _ = ffi::args(env, info);
    js_result(env, with_app(|app| app.zoom_extents()))
}

unsafe extern "C" fn cad_open_dxf(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let name = a.first().copied().and_then(|v| ffi::arg_string(env, v));
    let bytes = a.get(1).copied().and_then(|v| ffi::arg_bytes(env, v));
    match (name, bytes) {
        (Some(name), Some((len, data))) => {
            // SAFETY: `data`/`len` describe the ArrayBuffer Node-API handed us; it stays
            // alive for this call and is only read.
            let bytes = unsafe { std::slice::from_raw_parts(data as *const u8, len) };
            js_result(env, with_app(|app| app.open_dxf(&name, bytes)))
        }
        _ => ffi::js_error(env, "cadOpenDxf(name, arrayBuffer)"),
    }
}

unsafe extern "C" fn cad_save_dxf(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let _ = ffi::args(env, info);
    js_result(env, with_app(|app| app.save_dxf()))
}

unsafe extern "C" fn cad_state(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let _ = ffi::args(env, info);
    js_result(env, with_app(|app| app.state_json()))
}

unsafe extern "C" fn cad_doc_switch(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let index = a.first().copied().and_then(|v| ffi::arg_f64(env, v));
    match index {
        Some(i) if i >= 0.0 => js_result(env, with_app(|app| app.doc_switch(i as usize))),
        _ => ffi::js_error(env, "cadDocSwitch(index)"),
    }
}

unsafe extern "C" fn cad_grip_edit(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    // Arg: [[handle, index], …] — numbers from the shell's grip selection.
    let raw = a.first().copied().and_then(|v| ffi::arg_bytes(env, v));
    match raw {
        Some((len, data)) => {
            // SAFETY: `data`/`len` describe the loader-provided ArrayBuffer, read-only here.
            let bytes = unsafe { std::slice::from_raw_parts(data as *const u8, len) };
            let u64s: Vec<u64> = bytes
                .chunks_exact(8)
                .map(|c| u64::from_le_bytes(c.try_into().unwrap_or([0; 8])))
                .collect();
            let grips: Vec<(u64, usize)> = u64s
                .chunks(2)
                .filter(|c| c.len() == 2)
                .map(|c| (c[0], c[1] as usize))
                .collect();
            js_result(env, with_app(|app| app.grip_edit(&grips)))
        }
        None => ffi::js_error(env, "cadGripEdit(arrayBuffer of u64 pairs)"),
    }
}

unsafe extern "C" fn cad_zoom_window(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    let a = ffi::args(env, info);
    let num = |i: usize| a.get(i).copied().and_then(|v| ffi::arg_f64(env, v));
    match (num(0), num(1), num(2), num(3)) {
        (Some(x1), Some(y1), Some(x2), Some(y2)) => {
            js_result(env, with_app(|app| app.zoom_window(x1, y1, x2, y2)))
        }
        _ => ffi::js_error(env, "cadZoomWindow(x1, y1, x2, y2)"),
    }
}

unsafe extern "C" fn cad_frame(env: ffi::Env, info: ffi::CallbackInfo) -> ffi::Value {
    // The shell owns ONE reusable ArrayBuffer and passes it in; we fill it in place.
    // Zero per-frame allocation — under host memory pressure every large allocation
    // (napi_create_arraybuffer, image.createPixelMap) stalls the JS thread, which ANR'd.
    let a = ffi::args(env, info);
    let buf = a.first().copied().and_then(|v| ffi::arg_bytes(env, v));
    match buf {
        Some((len, data)) => {
            // SAFETY: `data`/`len` describe the ArrayBuffer the loader handed us; writing
            // stays within its bounds (frame_into fills at most out.len() bytes).
            let out = unsafe { std::slice::from_raw_parts_mut(data as *mut u8, len) };
            let written = with_app(|app| render::frame_into(app, out)).unwrap_or(0);
            ffi::js_int64(env, written as i64)
        }
        None => ffi::js_int64(env, 0),
    }
}
