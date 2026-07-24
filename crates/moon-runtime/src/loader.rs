//! Runtime extension points for in-memory Lua chunks and host-side errors.

use moon_base::{
    cstr, ffi, laux,
    laux::{LuaStack, LuaState},
};
use std::{ffi::CString, sync::Arc};

/// A Lua chunk owned by a host-side loader.
#[derive(Clone, Debug)]
pub struct LuaChunk {
    pub source: Arc<[u8]>,
    /// Lua source name used in diagnostics, usually an `@...` chunk name.
    pub name: Arc<str>,
}

/// Resolves in-memory Lua modules without coupling the runtime to a compiler.
pub trait LuaModuleLoader: Send + Sync + 'static {
    fn load_entry(&self, source: &str) -> Option<LuaChunk>;
    fn load_module(&self, module: &str) -> Option<LuaChunk>;
}

/// Phase at which a protected Lua call failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LuaErrorPhase {
    Init,
    Dispatch,
}

/// Context supplied to a host-side Lua error formatter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LuaErrorContext {
    pub actor_id: u32,
    pub actor_name: String,
    pub source: String,
    pub phase: LuaErrorPhase,
}

/// Converts raw Lua errors into host-facing diagnostics.
pub trait LuaErrorReporter: Send + Sync + 'static {
    fn format_error(&self, context: &LuaErrorContext, raw: &str) -> String;
}

/// Load an in-memory chunk onto the Lua stack.
///
/// # Safety
/// `state` must point to a live Lua state, and `chunk` must remain valid for
/// the duration of the call.
pub unsafe fn load_chunk(state: LuaState, chunk: &LuaChunk) -> i32 {
    let name = CString::new(chunk.name.as_bytes()).expect("Lua chunk names cannot contain NUL");
    unsafe {
        ffi::luaL_loadbufferx(
            state.as_ptr(),
            chunk.source.as_ptr() as *const std::ffi::c_char,
            chunk.source.len(),
            name.as_ptr(),
            std::ptr::null(),
        )
    }
}

unsafe extern "C-unwind" fn loader_gc(state: *mut ffi::lua_State) -> i32 {
    unsafe {
        let ptr = ffi::lua_touserdata(state, 1) as *mut Arc<dyn LuaModuleLoader>;
        if !ptr.is_null() {
            drop(Box::from_raw(ptr));
        }
    }
    0
}

unsafe fn loader_from_upvalue(
    state: *mut ffi::lua_State,
    index: i32,
) -> Option<&'static Arc<dyn LuaModuleLoader>> {
    unsafe {
        let ptr = ffi::lua_touserdata(state, ffi::lua_upvalueindex(index));
        (!ptr.is_null()).then(|| &*(ptr as *const Arc<dyn LuaModuleLoader>))
    }
}

unsafe extern "C-unwind" fn module_loader(state: *mut ffi::lua_State) -> i32 {
    let lua_state = LuaState::new(state).expect("Lua module loader called with null state");
    match unsafe { laux::with_context(lua_state, module_loader_impl) } {
        Ok(result) => result,
        Err(error) => unsafe {
            laux::lua_push(lua_state, error);
            ffi::lua_error(state)
        },
    }
}

fn module_loader_impl(lua: &mut LuaStack<'_>) -> Result<i32, String> {
    let state = lua.state();
    let loader = unsafe { loader_from_upvalue(state.as_ptr(), 1) }
        .ok_or_else(|| "Lua module loader state is gone".to_string())?;
    let module = lua
        .value(ffi::lua_upvalueindex(2))
        .as_str()
        .ok_or_else(|| "Rua module name is not valid UTF-8".to_string())?
        .to_owned();
    let chunk = loader
        .load_module(&module)
        .ok_or_else(|| format!("Rua module `{module}` disappeared from loader registry"))?;
    let status = unsafe { load_chunk(state, &chunk) };
    if status != ffi::LUA_OK {
        let message = lua
            .value(-1)
            .as_string_lossy()
            .map(|message| message.into_owned())
            .unwrap_or_else(|| "Rua module failed to load".to_string());
        return Err(message);
    }
    unsafe {
        // `require` invokes this closure with `(module_name, extra)`. Move the
        // compiled chunk before those arguments and execute it so the return
        // value is the module value, rather than the chunk function itself.
        ffi::lua_insert(state.as_ptr(), 1);
        let status = ffi::lua_pcall(state.as_ptr(), 2, 1, 0);
        if status != ffi::LUA_OK {
            let message = lua
                .value(-1)
                .as_string_lossy()
                .map(|message| message.into_owned())
                .unwrap_or_else(|| "Rua module execution failed".to_string());
            return Err(message);
        }
    }
    Ok(1)
}

unsafe extern "C-unwind" fn module_searcher(state: *mut ffi::lua_State) -> i32 {
    let lua_state = LuaState::new(state).expect("Lua searcher called with null state");
    match unsafe { laux::with_context(lua_state, module_searcher_impl) } {
        Ok(result) => result,
        Err(error) => unsafe {
            laux::lua_push(lua_state, error);
            ffi::lua_error(state)
        },
    }
}

fn module_searcher_impl(lua: &mut LuaStack<'_>) -> Result<i32, String> {
    let state = lua.state();
    let module = lua
        .value(1)
        .as_str()
        .ok_or_else(|| "bad argument #1 (valid UTF-8 string expected)".to_string())?
        .to_owned();
    let Some(loader) = (unsafe { loader_from_upvalue(state.as_ptr(), 1) }) else {
        laux::lua_push(state, "\n\tRua loader registry is unavailable");
        return Ok(1);
    };
    if loader.load_module(&module).is_none() {
        laux::lua_push(state, format!("\n\tno Rua module `{module}`"));
        return Ok(1);
    }

    unsafe {
        // Keep the userdata as an upvalue of the returned loader closure so
        // dropping/replacing package.searchers cannot free the registry early.
        ffi::lua_pushvalue(state.as_ptr(), ffi::lua_upvalueindex(1));
        laux::lua_push(state, module.as_str());
        ffi::lua_pushcclosure(state.as_ptr(), module_loader, 2);
        laux::lua_push(state, module.as_str());
    }
    Ok(2)
}

/// Install the Rua searcher before Lua's filesystem searcher.
pub fn install_module_searcher(
    state: LuaState,
    loader: Arc<dyn LuaModuleLoader>,
) -> Result<(), String> {
    unsafe {
        ffi::lua_getglobal(state.as_ptr(), cstr!("package"));
        if ffi::lua_type(state.as_ptr(), -1) != ffi::LUA_TTABLE {
            ffi::lua_settop(state.as_ptr(), 0);
            return Err("Lua package table is unavailable".to_string());
        }
        ffi::lua_getfield(state.as_ptr(), -1, cstr!("searchers"));
        if ffi::lua_type(state.as_ptr(), -1) != ffi::LUA_TTABLE {
            ffi::lua_settop(state.as_ptr(), 0);
            return Err("Lua package.searchers table is unavailable".to_string());
        }
        let searchers = ffi::lua_gettop(state.as_ptr());
        let length = ffi::lua_rawlen(state.as_ptr(), searchers);
        for index in (2..=length as i64).rev() {
            ffi::lua_rawgeti(state.as_ptr(), searchers, index);
            ffi::lua_rawseti(state.as_ptr(), searchers, index + 1);
        }

        let userdata = ffi::lua_newuserdatauv(
            state.as_ptr(),
            std::mem::size_of::<Arc<dyn LuaModuleLoader>>(),
            0,
        ) as *mut Arc<dyn LuaModuleLoader>;
        if userdata.is_null() {
            ffi::lua_settop(state.as_ptr(), 0);
            return Err("cannot allocate Lua module loader userdata".to_string());
        }
        userdata.write(loader);
        if ffi::luaL_newmetatable(state.as_ptr(), cstr!("moon.lua_module_loader")) != 0 {
            ffi::lua_pushcfunction(state.as_ptr(), loader_gc);
            ffi::lua_setfield(state.as_ptr(), -2, cstr!("__gc"));
        }
        ffi::lua_setmetatable(state.as_ptr(), -2);
        ffi::lua_pushcclosure(state.as_ptr(), module_searcher, 1);
        ffi::lua_rawseti(state.as_ptr(), searchers, 2);
        ffi::lua_settop(state.as_ptr(), 0);
    }
    Ok(())
}
