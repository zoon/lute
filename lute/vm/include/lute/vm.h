#pragma once

#include "lute/spawn.h"

#include "lua.h"
#include "lualib.h"

// open the library as a standard global luau library
int luaopen_vm(lua_State* L);
// open the library as a table on top of the stack
int luteopen_vm(lua_State* L);

namespace vm
{

int lua_defer(lua_State* L);
int lua_gcstop(lua_State* L);
int lua_gcrestart(lua_State* L);
int lua_gccollect(lua_State* L);
int lua_gccount(lua_State* L);
int lua_gcisrunning(lua_State* L);

static const luaL_Reg lib[] = {
    {"create", lua_spawn},
    {"gcstop", lua_gcstop},
    {"gcrestart", lua_gcrestart},
    {"gccollect", lua_gccollect},
    {"gccount", lua_gccount},
    {"gcisrunning", lua_gcisrunning},
    {nullptr, nullptr},
};

} // namespace vm
