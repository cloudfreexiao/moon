#include "common/http_utility.hpp"
#include "common/lua_utility.hpp"
#include "lua.hpp"

using namespace moon;

static int lhttp_parse_request(lua_State* L) {
    std::string_view data = lua_check<std::string_view>(L, 1);
    std::string_view method;
    std::string_view path;
    std::string_view query_string;
    std::string_view version;
    http::case_insensitive_multimap_view header;
    if (bool ok = http::request_parser::parse(data, method, path, query_string, version, header);
        !ok)
    {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Parse http request failed");
        return 2;
    }

    lua_createtable(L, 0, 8);
    luaL_rawsetfield(L, -3, "method", lua_pushlstring(L, method.data(), method.size()));
    auto urlpath = http::percent::decode(path);
    luaL_rawsetfield(L, -3, "path", lua_pushlstring(L, urlpath.data(), urlpath.size()));
    luaL_rawsetfield(
        L,
        -3,
        "query_string",
        lua_pushlstring(L, query_string.data(), query_string.size())
    );
    luaL_rawsetfield(L, -3, "version", lua_pushlstring(L, version.data(), version.size()));

    lua_pushliteral(L, "headers");
    lua_createtable(L, 0, (int)header.size());
    std::string tmp;
    for (const auto& [k, v]: header) {
        tmp.assign(k.data(), k.size());
        moon::lower(tmp);
        lua_pushlstring(L, tmp.data(), tmp.size());
        lua_pushlstring(L, v.data(), v.size());
        lua_rawset(L, -3);
    }
    lua_rawset(L, -3);
    return 1;
}

static int lhttp_parse_response(lua_State* L) {
    std::string_view data = lua_check<std::string_view>(L, 1);
    std::string_view version;
    std::string_view status_code;
    http::case_insensitive_multimap_view header;
    if (bool ok = http::response_parser::parse(data, version, status_code, header); !ok) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Parse http response failed");
        return 2;
    }

    lua_createtable(L, 0, 6);
    luaL_rawsetfield(L, -3, "version", lua_pushlstring(L, version.data(), version.size()));
    luaL_rawsetfield(
        L,
        -3,
        "status_code",
        lua_pushlstring(L, status_code.data(), status_code.size())
    );
    lua_pushliteral(L, "headers");
    lua_createtable(L, 0, (int)header.size());
    std::string tmp;
    for (const auto& [k, v]: header) {
        tmp.assign(k.data(), k.size());
        moon::lower(tmp);
        lua_pushlstring(L, tmp.data(), tmp.size());
        lua_pushlstring(L, v.data(), v.size());
        lua_rawset(L, -3);
    }
    lua_rawset(L, -3);
    return 1;
}

static int lhttp_parse_query_string(lua_State* L) {
    std::string_view data = lua_check<std::string_view>(L, 1);
    http::case_insensitive_multimap cim = http::query_string::parse(data);
    lua_createtable(L, 0, (int)cim.size());
    for (const auto& [k, v]: cim) {
        lua_pushlstring(L, k.data(), k.size());
        lua_pushlstring(L, v.data(), v.size());
        lua_rawset(L, -3);
    }
    return 1;
}

static int lhttp_create_query_string(lua_State* L) {
    luaL_checktype(L, -1, LUA_TTABLE);
    http::case_insensitive_multimap cim;
    lua_pushnil(L);
    while (lua_next(L, -2)) {
        cim.emplace(lua_check<std::string_view>(L, -2), lua_check<std::string_view>(L, -1));
        lua_pop(L, 1);
    }
    std::string s = http::query_string::create(cim);
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

static int lhttp_urlencode(lua_State* L) {
    std::string_view data = lua_check<std::string_view>(L, 1);
    std::string s = http::percent::encode(data);
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

static int lhttp_urldecode(lua_State* L) {
    std::string_view data = lua_check<std::string_view>(L, 1);
    std::string s = http::percent::decode(data);
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

extern "C" {
int LUAMOD_API luaopen_http_core(lua_State* L) {
    luaL_Reg l[] = {
        { "parse_request", lhttp_parse_request },
        { "parse_response", lhttp_parse_response },
        { "create_query_string", lhttp_create_query_string },
        { "parse_query_string", lhttp_parse_query_string },
        { "urlencode", lhttp_urlencode },
        { "urldecode", lhttp_urldecode },
        { NULL, NULL },
    };
    luaL_newlib(L, l);
    return 1;
}
}
