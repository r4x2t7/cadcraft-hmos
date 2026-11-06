//! Node-API (`libace_napi.z.so`) externs for the OHOS module.
//!
//! The only shared library this crate links against. All types are opaque handles and every
//! struct here is a documented, stable C ABI (`napi_module`, `napi_property_descriptor`), so
//! there is no platform struct-layout risk. `unsafe` lives only in this file and in the
//! thin wrappers at the bottom; the rest of the crate stays panic-free and calls these
//! wrappers as ordinary safe functions.

#![allow(unsafe_code)]

use std::ffi::{c_char, c_void, CString};

/// `napi_env`: the Node-API execution environment (opaque).
pub type Env = *mut c_void;
/// `napi_value`: a JavaScript value (opaque).
pub type Value = *mut c_void;
/// `napi_callback_info`: call-site information (opaque).
pub type CallbackInfo = *mut c_void;
/// `napi_addon_register_func`.
pub type AddonRegisterFunc = Option<unsafe extern "C" fn(Env, Value) -> Value>;
/// `napi_callback`.
pub type NapiCallback = Option<unsafe extern "C" fn(Env, CallbackInfo) -> Value>;

/// `napi_module` — the OHOS Node-API module descriptor. Field order is the documented C ABI
/// (same shape as Node's `node::napi_module`): the ArkTS loader matches `nm_modname` against
/// the requested `lib<name>.so` and calls `nm_register_func` once with the `exports` object.
#[repr(C)]
pub struct NapiModule {
    pub nm_version: i32,
    pub nm_flags: u32,
    pub nm_filename: *const c_char,
    pub nm_register_func: AddonRegisterFunc,
    pub nm_modname: *const c_char,
    pub nm_priv: *const c_void,
    pub reserved: [*mut c_void; 4],
}

unsafe impl Sync for NapiModule {}

/// `napi_property_descriptor` (stable C ABI, as in Node).
#[repr(C)]
pub struct PropertyDescriptor {
    pub utf8name: *const c_char,
    pub name: Value,
    pub method: NapiCallback,
    pub getter: NapiCallback,
    pub setter: NapiCallback,
    pub value: Value,
    pub attributes: u32,
    pub data: *mut c_void,
}

// The complete Node-API surface this module may need (the exports grow with the UI shell);
// unused entries stay declared on purpose.
#[allow(dead_code)]
#[link(name = "ace_napi.z")]
unsafe extern "C" {
    pub fn napi_module_register(module: *const NapiModule);
    pub fn napi_get_cb_info(
        env: Env, info: CallbackInfo, argc: *mut usize, argv: *mut Value, this_arg: *mut Value,
        data: *mut *mut c_void,
    ) -> i32;
    pub fn napi_create_string_utf8(env: Env, s: *const c_char, len: usize, out: *mut Value) -> i32;
    pub fn napi_get_value_string_utf8(
        env: Env, v: Value, buf: *mut c_char, size: usize, result: *mut usize,
    ) -> i32;
    pub fn napi_create_double(env: Env, v: f64, out: *mut Value) -> i32;
    pub fn napi_get_value_double(env: Env, v: Value, out: *mut f64) -> i32;
    pub fn napi_create_int64(env: Env, v: i64, out: *mut Value) -> i32;
    pub fn napi_get_value_int64(env: Env, v: Value, out: *mut i64) -> i32;
    pub fn napi_get_boolean(env: Env, v: bool, out: *mut Value) -> i32;
    pub fn napi_create_object(env: Env, out: *mut Value) -> i32;
    pub fn napi_set_named_property(env: Env, obj: Value, name: *const c_char, v: Value) -> i32;
    pub fn napi_get_named_property(env: Env, obj: Value, name: *const c_char, out: *mut Value) -> i32;
    pub fn napi_create_arraybuffer(env: Env, len: usize, data: *mut *mut c_void, out: *mut Value) -> i32;
    pub fn napi_get_arraybuffer_info(env: Env, v: Value, data: *mut *mut c_void, len: *mut usize) -> i32;
    pub fn napi_define_properties(env: Env, obj: Value, count: usize, props: *const PropertyDescriptor) -> i32;
    pub fn napi_get_undefined(env: Env, out: *mut Value) -> i32;
    pub fn napi_throw_error(env: Env, code: *const c_char, msg: *const c_char) -> i32;
}

// ---------------- safe wrappers ----------------

/// A JavaScript string argument, or `None` for non-strings.
pub fn arg_string(env: Env, v: Value) -> Option<String> {
    if v.is_null() {
        return None;
    }
    unsafe {
        let mut len: usize = 0;
        // Call once with size 0 to learn the length, then again to fill the buffer.
        if napi_get_value_string_utf8(env, v, std::ptr::null_mut(), 0, &mut len) != 0 {
            return None;
        }
        let mut buf = vec![0u8; len + 1];
        let mut written: usize = 0;
        let status = napi_get_value_string_utf8(
            env, v, buf.as_mut_ptr() as *mut c_char, buf.len(), &mut written,
        );
        if status != 0 {
            return None;
        }
        buf.truncate(written);
        Some(String::from_utf8_lossy(&buf).into_owned())
    }
}

/// A JavaScript number argument, or `None`.
pub fn arg_f64(env: Env, v: Value) -> Option<f64> {
    if v.is_null() {
        return None;
    }
    let mut out: f64 = 0.0;
    let ok = unsafe { napi_get_value_double(env, v, &mut out) } == 0;
    if ok && out.is_finite() {
        Some(out)
    } else {
        None
    }
}

/// A JavaScript ArrayBuffer argument: length and read pointer, or `None`.
pub fn arg_bytes(env: Env, v: Value) -> Option<(usize, *mut c_void)> {
    if v.is_null() {
        return None;
    }
    let mut data: *mut c_void = std::ptr::null_mut();
    let mut len: usize = 0;
    let ok = unsafe { napi_get_arraybuffer_info(env, v, &mut data, &mut len) } == 0;
    if ok && !data.is_null() {
        Some((len, data))
    } else {
        None
    }
}

/// The positional arguments of the current call.
pub fn args(env: Env, info: CallbackInfo) -> Vec<Value> {
    let mut argc: usize = 0;
    unsafe {
        // First call with argv = null learns the count.
        napi_get_cb_info(env, info, &mut argc, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut());
        let mut argv: Vec<Value> = vec![std::ptr::null_mut(); argc.min(16)];
        let mut real: usize = argv.len();
        napi_get_cb_info(env, info, &mut real, argv.as_mut_ptr(), std::ptr::null_mut(), std::ptr::null_mut());
        argv
    }
}

/// Build a JavaScript string value ("undefined" on failure — callers also fail gracefully).
pub fn js_string(env: Env, s: &str) -> Value {
    let mut out: Value = std::ptr::null_mut();
    let Ok(c) = CString::new(s) else { return std::ptr::null_mut() };
    unsafe {
        let status = napi_create_string_utf8(env, c.as_ptr(), s.len(), &mut out);
        if status != 0 {
            std::ptr::null_mut()
        } else {
            out
        }
    }
}

/// The standard JSON error reply: `{"ok":false,"error":"..."}`.
pub fn js_error(env: Env, msg: &str) -> Value {
    let reply = serde_json::json!({ "ok": false, "error": msg }).to_string();
    js_string(env, &reply)
}

/// A JSON object `{"ok":true, ...}` as a JavaScript string.
pub fn js_ok(env: Env, extra: serde_json::Value) -> Value {
    let mut v = serde_json::json!({ "ok": true });
    if let (Some(obj), Some(extra)) = (v.as_object_mut(), extra.as_object()) {
        for (k, val) in extra {
            obj.insert(k.clone(), val.clone());
        }
    }
    js_string(env, &v.to_string())
}

/// JavaScript `undefined` (for void exports).
pub fn js_undefined(env: Env) -> Value {
    let mut out: Value = std::ptr::null_mut();
    unsafe {
        napi_get_undefined(env, &mut out);
    }
    out
}

/// A fresh ArrayBuffer holding `bytes` (empty ArrayBuffer on failure).
pub fn js_arraybuffer(env: Env, bytes: &[u8]) -> Value {
    let mut out: Value = std::ptr::null_mut();
    let mut data: *mut c_void = std::ptr::null_mut();
    unsafe {
        if napi_create_arraybuffer(env, bytes.len(), &mut data, &mut out) != 0 {
            return std::ptr::null_mut();
        }
        if !data.is_null() && !bytes.is_empty() {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), data as *mut u8, bytes.len());
        }
    }
    out
}

/// Helper for `napi_define_properties`: one named method.
pub fn prop(name: &str, method: NapiCallback) -> (CString, PropertyDescriptor) {
    let cname = CString::new(name).unwrap_or_else(|_| CString::new("x").unwrap_or_default());
    let descriptor = PropertyDescriptor {
        utf8name: cname.as_ptr(),
        name: std::ptr::null_mut(),
        method,
        getter: None,
        setter: None,
        value: std::ptr::null_mut(),
        attributes: 0,
        data: std::ptr::null_mut(),
    };
    (cname, descriptor)
}
