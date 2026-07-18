//! Runtime extension points for in-memory Lua chunks and host-side errors.

use moon_base::{cstr, ffi, laux, laux::LuaState};
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
    let Some(loader) = (unsafe { loader_from_upvalue(state, 1) }) else {
        laux::lua_error(
            LuaState::new(state).expect("Lua loader called with null state"),
            "Lua module loader state is gone".to_string(),
        );
    };
    let module = unsafe {
        laux::lua_to_str(
            LuaState::new(state).expect("Lua loader called with null state"),
            ffi::lua_upvalueindex(2),
        )
    };
    let Some(chunk) = loader.load_module(module) else {
        laux::lua_error(
            LuaState::new(state).expect("Lua loader called with null state"),
            format!("Rua module `{module}` disappeared from loader registry"),
        );
    };
    let status = unsafe {
        load_chunk(
            LuaState::new(state).expect("Lua loader called with null state"),
            &chunk,
        )
    };
    if status != ffi::LUA_OK {
        let message = unsafe {
            laux::lua_opt_str(
                LuaState::new(state).expect("Lua loader called with null state"),
                -1,
            )
        }
        .unwrap_or("Rua module failed to load")
        .to_string();
        laux::lua_error(
            LuaState::new(state).expect("Lua loader called with null state"),
            message,
        );
    }
    unsafe {
        // `require` invokes this closure with `(module_name, extra)`. Move the
        // compiled chunk before those arguments and execute it so the return
        // value is the module value, rather than the chunk function itself.
        ffi::lua_insert(state, 1);
        ffi::lua_call(state, 2, 1);
    }
    1
}

unsafe extern "C-unwind" fn module_searcher(state: *mut ffi::lua_State) -> i32 {
    let lua = LuaState::new(state).expect("Lua searcher called with null state");
    let module = unsafe { laux::lua_check_str(lua, 1) };
    let Some(loader) = (unsafe { loader_from_upvalue(state, 1) }) else {
        laux::lua_push(lua, "\n\tRua loader registry is unavailable");
        return 1;
    };
    if loader.load_module(module).is_none() {
        laux::lua_push(lua, format!("\n\tno Rua module `{module}`"));
        return 1;
    }

    unsafe {
        // Keep the userdata as an upvalue of the returned loader closure so
        // dropping/replacing package.searchers cannot free the registry early.
        ffi::lua_pushvalue(state, ffi::lua_upvalueindex(1));
        laux::lua_push(lua, module);
        ffi::lua_pushcclosure(state, module_loader, 2);
        laux::lua_push(lua, module);
    }
    2
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
