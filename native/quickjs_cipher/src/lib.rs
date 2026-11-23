use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use rquickjs::{Context, Runtime, qjs};
use serde_json::json;

const LIB: &str = include_str!("../../../assets/ejs/yt.solver.lib.min.js");
const CORE: &str = include_str!("../../../assets/ejs/yt.solver.core.min.js");

fn js_err(ctx: &rquickjs::Ctx, e: rquickjs::Error) -> anyhow::Error {
    match e {
        rquickjs::Error::Exception => {
            let exc = ctx.catch();
            let msg = exc.as_exception().and_then(|e| e.message()).unwrap_or_else(|| "unknown exception".into());
            let stack = exc.as_exception().and_then(|e| e.stack()).unwrap_or_default();
            anyhow::anyhow!("{msg}\n{stack}")
        }
        other => other.into(),
    }
}

pub fn preprocess(base: &str) -> anyhow::Result<String> {
    let rt = Runtime::new()?;
    rt.set_max_stack_size(64 << 20);
    let ctx = Context::full(&rt)?;
    ctx.with(|ctx| {
        let input = json!({
            "type": "player",
            "player": base,
            "output_preprocessed": true,
            "requests": []
        });
        let src = format!("{LIB}\nObject.assign(globalThis, lib);\n{CORE}\nJSON.stringify(jsc({input}))");
        let out: String = ctx.eval(src).map_err(|e| js_err(&ctx, e))?;
        let v: serde_json::Value = serde_json::from_str(&out)?;
        v["preprocessed_player"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("solver returned no preprocessed player: {out}"))
    })
}

pub fn compile_to_bytecode(pre: &str) -> anyhow::Result<Vec<u8>> {
    let rt = Runtime::new()?;
    rt.set_max_stack_size(64 << 20);
    let ctx = Context::full(&rt)?;
    let src = format!("var _r = {{n: null, sig: null}};\n(function (_result) {{\n{pre}\n}})(_r);\n\0");
    ctx.with(|ctx| unsafe {
        let c = ctx.as_raw().as_ptr();
        let flags = (qjs::JS_EVAL_TYPE_GLOBAL | qjs::JS_EVAL_FLAG_COMPILE_ONLY) as i32;
        let filename = c"solver.js";
        let f = qjs::JS_Eval(c, src.as_ptr().cast(), (src.len() - 1) as _, filename.as_ptr(), flags);
        if qjs::JS_IsException(f) {
            return Err(js_err(&ctx, rquickjs::Error::Exception));
        }
        let mut len = 0;
        let flags = (qjs::JS_WRITE_OBJ_BYTECODE | qjs::JS_WRITE_OBJ_STRIP_SOURCE | qjs::JS_WRITE_OBJ_STRIP_DEBUG) as i32;
        let buf = qjs::JS_WriteObject(c, &mut len, f, flags);
        qjs::JS_FreeValue(c, f);
        anyhow::ensure!(!buf.is_null(), "js: couldn't write bytecode");
        let out = std::slice::from_raw_parts(buf, len as usize).to_vec();
        qjs::js_free(c, buf.cast());
        Ok(out)
    })
}

pub fn solve(preprocessed: &str, n: Option<&str>, sig: Option<&str>) -> anyhow::Result<(Option<String>, Option<String>)> {
    let rt = Runtime::new()?;
    rt.set_max_stack_size(64 << 20);
    let ctx = Context::full(&rt)?;
    ctx.with(|ctx| {
        let setup = format!("var _r = {{n: null, sig: null}};\n(function (_result) {{\n{preprocessed}\n}})(_r);");
        let _: rquickjs::Value = ctx.eval(setup).map_err(|e| js_err(&ctx, e))?;
        
        let run = |kind: &str, input: Option<&str>| -> anyhow::Result<Option<String>> {
            let Some(input) = input else { return Ok(None) };
            let src = format!("_r.{kind}({})", serde_json::to_string(input)?);
            let out: String = ctx.eval(src).map_err(|e| js_err(&ctx, e))?;
            Ok(Some(out))
        };
        Ok((run("n", n)?, run("sig", sig)?))
    })
}

pub fn solve_bytecode(bc: &[u8], n: Option<&str>, sig: Option<&str>) -> anyhow::Result<(Option<String>, Option<String>)> {
    let rt = Runtime::new()?;
    rt.set_max_stack_size(64 << 20);
    let ctx = Context::full(&rt)?;
    ctx.with(|ctx| unsafe {
        let c = ctx.as_raw().as_ptr();
        let f = qjs::JS_ReadObject(c, bc.as_ptr(), bc.len() as _, qjs::JS_READ_OBJ_BYTECODE as i32);
        if qjs::JS_IsException(f) {
            return Err(js_err(&ctx, rquickjs::Error::Exception));
        }
        let r = qjs::JS_EvalFunction(c, f);
        if qjs::JS_IsException(r) {
            return Err(js_err(&ctx, rquickjs::Error::Exception));
        }
        qjs::JS_FreeValue(c, r);
        
        let run = |kind: &str, input: Option<&str>| -> anyhow::Result<Option<String>> {
            let Some(input) = input else { return Ok(None) };
            let src = format!("_r.{kind}({})", serde_json::to_string(input)?);
            let out: String = ctx.eval(src).map_err(|e| js_err(&ctx, e))?;
            Ok(Some(out))
        };
        Ok((run("n", n)?, run("sig", sig)?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn quickjs_cipher_preprocess(base_js: *const c_char) -> *mut c_char {
    if base_js.is_null() { return std::ptr::null_mut(); }
    let base_str = match CStr::from_ptr(base_js).to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    match preprocess(base_str) {
        Ok(res) => CString::new(res).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut()),
        Err(e) => {
            eprintln!("quickjs_cipher_preprocess error: {e}");
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn quickjs_cipher_solve(
    preprocessed: *const c_char,
    n: *const c_char,
    sig: *const c_char,
) -> *mut c_char {
    if preprocessed.is_null() { return std::ptr::null_mut(); }
    let preprocessed_str = match CStr::from_ptr(preprocessed).to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let n_opt = if n.is_null() {
        None
    } else {
        CStr::from_ptr(n).to_str().ok().filter(|s| !s.is_empty())
    };
    let sig_opt = if sig.is_null() {
        None
    } else {
        CStr::from_ptr(sig).to_str().ok().filter(|s| !s.is_empty())
    };
    
    match solve(preprocessed_str, n_opt, sig_opt) {
        Ok((n_res, sig_res)) => {
            let json_res = json!({
                "n": n_res,
                "sig": sig_res,
            });
            CString::new(json_res.to_string()).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
        }
        Err(e) => {
            eprintln!("quickjs_cipher_solve error: {e}");
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn quickjs_cipher_solve_bytecode(
    bc_ptr: *const u8,
    bc_len: usize,
    n: *const c_char,
    sig: *const c_char,
) -> *mut c_char {
    if bc_ptr.is_null() || bc_len == 0 { return std::ptr::null_mut(); }
    let bc = std::slice::from_raw_parts(bc_ptr, bc_len);
    let n_opt = if n.is_null() {
        None
    } else {
        CStr::from_ptr(n).to_str().ok().filter(|s| !s.is_empty())
    };
    let sig_opt = if sig.is_null() {
        None
    } else {
        CStr::from_ptr(sig).to_str().ok().filter(|s| !s.is_empty())
    };
    
    match solve_bytecode(bc, n_opt, sig_opt) {
        Ok((n_res, sig_res)) => {
            let json_res = json!({
                "n": n_res,
                "sig": sig_res,
            });
            CString::new(json_res.to_string()).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
        }
        Err(e) => {
            eprintln!("quickjs_cipher_solve_bytecode error: {e}");
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn quickjs_cipher_compile(
    preprocessed: *const c_char,
    out_len: *mut usize,
) -> *mut u8 {
    if preprocessed.is_null() || out_len.is_null() { return std::ptr::null_mut(); }
    let preprocessed_str = match CStr::from_ptr(preprocessed).to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    match compile_to_bytecode(preprocessed_str) {
        Ok(mut bc) => {
            *out_len = bc.len();
            let ptr = bc.as_mut_ptr();
            std::mem::forget(bc);
            ptr
        }
        Err(e) => {
            eprintln!("quickjs_cipher_compile error: {e}");
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn quickjs_cipher_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[no_mangle]
pub unsafe extern "C" fn quickjs_cipher_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        drop(Vec::from_raw_parts(ptr, len, len));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_eval_simple() {
        let rt = Runtime::new().unwrap();
        let ctx = Context::full(&rt).unwrap();
        ctx.with(|ctx| {
            let val: i32 = ctx.eval("1 + 2").unwrap();
            assert_eq!(val, 3);
        });
    }
}
