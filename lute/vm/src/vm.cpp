#include "lute/vm.h"

#include "lute/runtime.h"

int luaopen_vm(lua_State* L)
{
    luaL_register(L, "vm", vm::lib);

    return 1;
}

int luteopen_vm(lua_State* L)
{
    lua_createtable(L, 0, std::size(vm::lib));

    for (auto& [name, func] : vm::lib)
    {
        if (!name || !func)
            break;

        lua_pushcfunction(L, func, name);
        lua_setfield(L, -2, name);
    }

    lua_setreadonly(L, -1, 1);

    return 1;
}

namespace vm
{

int lua_gcstop(lua_State* L)
{
    lua_gc(L, LUA_GCSTOP, 0);
    return 0;
}

int lua_gcrestart(lua_State* L)
{
    lua_gc(L, LUA_GCRESTART, 0);
    return 0;
}

int lua_gccollect(lua_State* L)
{
    lua_gc(L, LUA_GCCOLLECT, 0);
    return 0;
}

int lua_gccount(lua_State* L)
{
    int count = lua_gc(L, LUA_GCCOUNT, 0);
    lua_pushinteger(L, count);
    return 1;
}

int lua_gcisrunning(lua_State* L)
{
    int running = lua_gc(L, LUA_GCISRUNNING, 0);
    lua_pushboolean(L, running);
    return 1;
}

} // namespace vm
