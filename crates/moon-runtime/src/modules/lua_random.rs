use moon_base::{cstr, ffi, laux, lreg_null, lreg_try, luaL_newlib};
use rand::RngExt;
use std::ffi::c_int;

use moon_base::laux::{LuaStack, LuaState};

fn table_to_i64_vec(lua: &LuaStack<'_>, index: c_int) -> Result<Vec<i64>, String> {
    let state = lua.state();
    if laux::lua_type(state, index) != laux::LuaType::Table {
        return Err(format!("argument #{} must be a table", index));
    }
    let abs_index = lua.abs_index(index);
    let len = unsafe { ffi::lua_rawlen(state.as_ptr(), abs_index) };
    let mut values = Vec::with_capacity(len);

    for i in 1..=len {
        unsafe {
            ffi::lua_rawgeti(state.as_ptr(), abs_index, i as ffi::lua_Integer);
            let mut is_num = 0;
            let value = ffi::lua_tointegerx(state.as_ptr(), -1, &mut is_num);
            ffi::lua_pop(state.as_ptr(), 1);
            if is_num == 0 {
                return Err(format!("table element #{} must be an integer", i));
            }
            values.push(value as i64);
        }
    }

    Ok(values)
}

fn checked_range_len(min: i64, max: i64) -> Option<i64> {
    max.checked_sub(min)?.checked_add(1)
}

fn rand_range(lua: &mut LuaStack<'_>) -> Result<c_int, String> {
    let min: i64 = lua.get(1).map_err(|e| format!("random.rand_range: {e}"))?;
    let max: i64 = lua.get(2).map_err(|e| format!("random.rand_range: {e}"))?;
    if min > max {
        return Err(format!(
            "random.rand_range: min value must be less than or equal to max value, got min={} and max={}",
            min, max
        ));
    }

    let value = rand::rng().random_range(min..=max);
    lua.push(value);
    Ok(1)
}

fn rand_range_some(lua: &mut LuaStack<'_>) -> Result<c_int, String> {
    let min: i64 = lua
        .get(1)
        .map_err(|e| format!("random.rand_range_some: {e}"))?;
    let max: i64 = lua
        .get(2)
        .map_err(|e| format!("random.rand_range_some: {e}"))?;
    let count: i64 = lua
        .get(3)
        .map_err(|e| format!("random.rand_range_some: {e}"))?;

    if min > max {
        return Err(format!(
            "random.rand_range_some: min value must be less than or equal to max value, got min={} and max={}",
            min, max
        ));
    }

    let Some(range_len) = checked_range_len(min, max) else {
        return Err("random.rand_range_some: range size overflow".to_string());
    };

    if count <= 0 || range_len < count {
        return Err(format!(
            "random.rand_range_some: count must be in range [1, {}], got {}",
            range_len, count
        ));
    }

    let count_usize = usize::try_from(count)
        .map_err(|_| "random.rand_range_some: count is too large".to_string())?;

    let mut rng = rand::rng();

    // Floyd's algorithm: `count` draws, each adding either index `j` or a
    // uniformly drawn `t <= j`. Yields a uniform random subset of [min, max]
    // without ever enumerating the range, so time and memory stay O(count)
    // whatever the range width. Order is not significant (set iteration order).
    let mut chosen = std::collections::HashSet::with_capacity(count_usize);
    for j in (range_len - count)..range_len {
        let t = rng.random_range(0..=j);
        let value = if chosen.contains(&(min + t)) {
            min + j
        } else {
            min + t
        };
        chosen.insert(value);
    }

    let table = laux::LuaTable::new(lua.state(), count_usize, 0);
    for (i, value) in chosen.into_iter().enumerate() {
        lua.push(value);
        table.rawseti(i + 1);
    }

    Ok(1)
}

fn randf_range(lua: &mut LuaStack<'_>) -> Result<c_int, String> {
    let min: f64 = lua.get(1).map_err(|e| format!("random.randf_range: {e}"))?;
    let max: f64 = lua.get(2).map_err(|e| format!("random.randf_range: {e}"))?;
    if !min.is_finite() || !max.is_finite() || min > max {
        return Err(format!(
            "random.randf_range: min and max must be finite with min <= max, got min={} and max={}",
            min, max
        ));
    }

    let value = if min == max {
        min
    } else {
        rand::rng().random_range(min..max)
    };
    lua.push(value);
    Ok(1)
}

fn randf_percent(lua: &mut LuaStack<'_>) -> Result<c_int, String> {
    let percent: f64 = lua
        .get(1)
        .map_err(|e| format!("random.randf_percent: {e}"))?;
    let value = percent > 0.0 && rand::rng().random_range(0.0..1.0) < percent;
    lua.push(value);
    Ok(1)
}

fn choose_weighted(values: &[i64], weights: &[i64]) -> Option<i64> {
    if weights.iter().any(|weight| *weight < 0) {
        return None;
    }

    let sum: i64 = weights.iter().copied().sum();
    if sum == 0 {
        return None;
    }

    let mut cutoff = rand::rng().random_range(0..sum);
    for (value, weight) in values.iter().zip(weights) {
        if cutoff < *weight {
            return Some(*value);
        }
        cutoff -= *weight;
    }

    values.last().copied()
}

fn rand_weight(lua: &mut LuaStack<'_>) -> Result<c_int, String> {
    let result = (|| {
        let values = table_to_i64_vec(lua, 1)?;
        let weights = table_to_i64_vec(lua, 2)?;
        if values.len() != weights.len() || values.is_empty() {
            return Err(
                "random.rand_weight: 'values' and 'weights' must be non-empty tables of equal length"
                    .to_string(),
            );
        }
        if weights.iter().any(|weight| *weight < 0) {
            return Err("random.rand_weight: weights must be non-negative".to_string());
        }
        Ok(choose_weighted(&values, &weights))
    })();

    match result {
        Ok(Some(value)) => {
            lua.push(value);
            Ok(1)
        }
        Ok(None) => Ok(0),
        Err(err) => Err(err),
    }
}

fn rand_weight_some(lua: &mut LuaStack<'_>) -> Result<c_int, String> {
    let count: i64 = lua
        .get(3)
        .map_err(|e| format!("random.rand_weight_some: {e}"))?;

    let result = (|| {
        let mut values = table_to_i64_vec(lua, 1)?;
        let mut weights = table_to_i64_vec(lua, 2)?;
        if values.len() != weights.len()
            || values.is_empty()
            || count < 0
            || values.len() < count as usize
        {
            return Err(format!(
                "random.rand_weight_some: 'values' and 'weights' must be non-empty tables of equal length, and 'count' must be in range [0, {}], got {}",
                values.len(),
                count
            ));
        }
        if weights.iter().any(|weight| *weight < 0) {
            return Err("random.rand_weight_some: weights must be non-negative".to_string());
        }

        let mut picked = Vec::with_capacity(count as usize);
        for _ in 0..count {
            let sum: i64 = weights.iter().copied().sum();
            if sum == 0 {
                return Ok(None);
            }

            let mut cutoff = rand::rng().random_range(0..sum);
            let mut index = 0;
            while cutoff >= weights[index] {
                cutoff -= weights[index];
                index += 1;
            }

            picked.push(values[index]);
            values.swap_remove(index);
            weights.swap_remove(index);
        }

        Ok(Some(picked))
    })();

    match result {
        Ok(Some(values)) => {
            let table = laux::LuaTable::new(lua.state(), values.len(), 0);
            for (idx, value) in values.into_iter().enumerate() {
                lua.push(value);
                table.rawseti(idx + 1);
            }
            Ok(1)
        }
        Ok(None) => Ok(0),
        Err(err) => Err(err),
    }
}

pub unsafe extern "C-unwind" fn luaopen_random(state: LuaState) -> c_int {
    let l = [
        lreg_try!("rand_range", rand_range),
        lreg_try!("rand_range_some", rand_range_some),
        lreg_try!("randf_range", randf_range),
        lreg_try!("randf_percent", randf_percent),
        lreg_try!("rand_weight", rand_weight),
        lreg_try!("rand_weight_some", rand_weight_some),
        lreg_null!(),
    ];

    luaL_newlib!(state, l);
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    use moon_base::laux::LuaGlobalState;
    use serial_test::serial;
    use std::ffi::CString;

    fn new_vm() -> (LuaState, LuaGlobalState) {
        unsafe {
            let raw = ffi::luaL_newstate();
            assert!(!raw.is_null());
            let state = LuaState::new(raw).unwrap();
            let guard = LuaGlobalState::new(state);
            ffi::luaL_openlibs(raw);
            ffi::luaL_requiref(
                raw,
                cstr!("random"),
                crate::not_null_wrapper!(luaopen_random),
                1,
            );
            ffi::lua_pop(raw, 1);
            (state, guard)
        }
    }

    fn run(state: LuaState, code: &str) -> Result<(), String> {
        unsafe {
            let c = CString::new(code).unwrap();
            if ffi::luaL_dostring(state.as_ptr(), c.as_ptr()) != ffi::LUA_OK {
                let err = ffi::lua_tostring(state.as_ptr(), -1);
                let msg = if err.is_null() {
                    "unknown error".to_string()
                } else {
                    std::ffi::CStr::from_ptr(err).to_string_lossy().into_owned()
                };
                ffi::lua_pop(state.as_ptr(), 1);
                Err(msg)
            } else {
                Ok(())
            }
        }
    }

    /// The frequency and subset checks are the ones that catch a sampling bug
    /// still yielding distinct in-range values; distinctness alone would not.
    #[test]
    #[serial]
    fn rand_range_some_is_uniform_distinct_and_in_range() {
        let (state, _guard) = new_vm();
        let code = r#"
            local random = require("random")

            -- (1) Distinctness, range, and per-value frequency. 600 draws x 3
            -- values = 1800 picks over 6 values => ~300 each, sigma ~16.
            local counts = {}
            for _ = 1, 600 do
                local r = random.rand_range_some(1, 6, 3)
                assert(#r == 3, "expected 3 values, got " .. #r)
                local seen = {}
                for _, v in ipairs(r) do
                    assert(v >= 1 and v <= 6, "out of range: " .. v)
                    assert(not seen[v], "duplicate: " .. v)
                    seen[v] = true
                    counts[v] = (counts[v] or 0) + 1
                end
            end
            for v = 1, 6 do
                local c = counts[v] or 0
                assert(c > 200 and c < 400, "value " .. v .. " appeared " .. c .. " times")
            end

            -- (2) count == range_len must yield the whole range, each once.
            local full = random.rand_range_some(1, 5, 5)
            assert(#full == 5, "expected 5 values, got " .. #full)
            local got = {}
            for _, v in ipairs(full) do
                assert(not got[v], "duplicate in full range: " .. v)
                got[v] = true
            end
            for v = 1, 5 do assert(got[v], "missing " .. v) end

            -- (3) Every 2-subset of 1..3 must occur about equally often.
            local sub = {}
            for _ = 1, 300 do
                local r = random.rand_range_some(1, 3, 2)
                local a, b = r[1], r[2]
                if a > b then a, b = b, a end
                local key = a .. "," .. b
                sub[key] = (sub[key] or 0) + 1
            end
            for _, key in ipairs({"1,2", "1,3", "2,3"}) do
                local c = sub[key] or 0
                assert(c > 50 and c < 150, "subset " .. key .. " occurred " .. c .. " times")
            end

            -- (4) count == 1, and a wide sparse range still costs O(count).
            local one = random.rand_range_some(1, 1, 1)
            assert(#one == 1 and one[1] == 1, "single-element range")
            local wide = random.rand_range_some(0, 1000000000, 5)
            local wseen = {}
            for _, v in ipairs(wide) do
                assert(v >= 0 and v <= 1000000000, "out of wide range: " .. v)
                assert(not wseen[v], "duplicate in wide range: " .. v)
                wseen[v] = true
            end
        "#;
        run(state, code).expect("sampling must be uniform, distinct and in range");
    }
}
