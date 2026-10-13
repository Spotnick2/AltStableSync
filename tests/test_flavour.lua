------------------------------------------------------------
-- test_flavour.lua - A42: a build or project change is a normal login (#11)
--
-- "Beta build/project ID changes normally: no false flavour migration or
-- destructive catalog reset" (docs/ACCEPTANCE.md). A build or WOW_PROJECT_ID
-- change alone never migrates, resets, quarantines or disables the catalog,
-- and never writes game state. (LibAccountSync's own project bookkeeping, in
-- the Link addon's store, is the library's business and its own tests'.)
--
-- Each login is a separate process (tests/flavour_session.lua): LibStub,
-- the library, timers, WOW_PROJECT_ID and frames start fresh, as in a real
-- client. A seed session on 70245 / project 1 makes the LibAccountSync store;
-- every case then loads the same saved store (tests/flavour_fixture.lua).
-- This proves the regression under the stubs, not a future client.
------------------------------------------------------------

dofile("tests/harness.lua")

-- The interpreter running this test: the runner's -Lua choice on Windows,
-- lua5.1 on CI.
local lua = arg and arg[-1]
check("the interpreter is known", type(lua) == "string" and lua ~= "")
local windows = package.config:sub(1, 1) == "\\"

local function quote(s)
    if windows then return '"' .. s .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Run one session. It passes only if its last line is the pass marker.
local function session(name, ...)
    local parts = { quote(lua), quote("tests/flavour_session.lua") }
    for _, a in ipairs({ ... }) do parts[#parts + 1] = quote(tostring(a)) end
    local cmd = table.concat(parts, " ") .. " 2>&1"
    -- cmd.exe strips one pair of quotes around a command that starts with one.
    if windows then cmd = '"' .. cmd .. '"' end
    local p = io.popen(cmd)
    local out = p and p:read("*a") or ""
    if p then p:close() end
    local last
    for line in out:gmatch("[^\r\n]+") do last = line end
    local ok = last == "FLAVOUR-SESSION-PASSED " .. name
    check("session " .. name .. " passed", ok, not ok and ("\n" .. out) or nil)
    return ok
end

local las = os.tmpname()
if windows and las:sub(1, 1) == "\\" then las = (os.getenv("TEMP") or ".") .. las end
local function cleanup() os.remove(las) end

local ok, err = pcall(function()
    if not session("seed", "seed", las) then return end
    -- The store was written on 70245 / project 1.
    session("a", "case", "a", "70245", 1, las)        -- control
    session("b", "case", "b", "70338", 1, las)        -- the build only
    session("c", "case", "c", "70245", 18, las)       -- the project only, 1 -> 18 (measured on the beta)
    session("d", "case", "d", "70338", 18, las)       -- both
    session("e", "case", "e", "99999", 18, las)       -- a build nobody measured
end)
cleanup()
check("no error running the sessions", ok, tostring(err))
finish("test_flavour")
