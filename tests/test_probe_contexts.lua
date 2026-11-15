------------------------------------------------------------
-- test_probe_contexts.lua - AltStableSyncProbe's `contexts` procedure (#106)
--
-- `/fp steps sync contexts` driven through the host against the mock: one
-- test chord bound in memory in the None and the gamepad contexts, read
-- every way, and put back as it was in each; stopped half way, `/fp sync
-- contexts restore` puts it back. Nothing is ever saved.
--
-- Needs a ForeverProbe checkout ($FOREVERPROBE, else ..\ForeverProbe). It is
-- private and local, so CI (FOREVERPROBE_OPTIONAL=1) skips this file.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
dofile("tests/wow_game.lua")

local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
do
    local toc = io.open(root .. "/ForeverProbe.toc", "rb")
    if not toc then
        if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
            Kit.skip("test_probe_contexts", "no ForeverProbe checkout; probe tests run locally")
        end
        error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
    end
    toc:close()
end

local G = WoW.game
WoW.reset()
local errors = {}
function geterrorhandler() return function(e) errors[#errors + 1] = tostring(e) end end
SlashCmdList = SlashCmdList or {}

local KEY = "ALT-CTRL-SHIFT-F11"
G.setup{
    guid = "Player-70-CTX", class = "PRIEST", spells = {}, macros = {}, actions = {},
    keys = { [KEY] = "JUMP", ["1"] = "ACTIONBUTTON1" },     -- the owner's own binding on the test chord
    padKeys = { ["PAD1"] = "GAMEPADACTIONBUTTON1" },
}
local function snapshot()
    local k, p = {}, {}
    for a, b in pairs(G.keys) do k[a] = b end
    for a, b in pairs(G.padKeys) do p[a] = b end
    return k, p
end
local keysBefore, padBefore = snapshot()

local files = {}
for line in io.open(root .. "/ForeverProbe.toc", "rb"):read("*a"):gmatch("[^\r\n]+") do
    if line:match("%.lua$") and not line:match("^#") then files[#files + 1] = root .. "/" .. line end
end
for _, f in ipairs(files) do assert(loadfile(f))("ForeverProbe", {}) end
WoW.fire("ADDON_LOADED", "ForeverProbe")
local NS = {}
for line in io.lines("Tools/AltStableSyncProbe/AltStableSyncProbe.toc") do
    line = line:gsub("\r", "")
    if line:match("%.lua$") and not line:match("^#") then
        assert(loadfile("Tools/AltStableSyncProbe/" .. line))("AltStableSyncProbe", NS)
    end
end
WoW.fire("ADDON_LOADED", "AltStableSyncProbe")
WoW.fire("PLAYER_LOGIN")

local S = ForeverProbe.Steps
local function fp(msg) SlashCmdList.FOREVERPROBE(msg) end
local function rec() return ForeverProbeDB.steps.records["AltStableSyncProbe/contexts"] end
local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end
local function saves()
    local n = 0
    for _, c in ipairs(G.calls) do if c == "SaveBindings" then n = n + 1 end end
    return n
end

eq("the test chord", NS._measure.TEST_KEY, KEY)

-- The run.
fp("steps sync contexts")
S.Next()                                            -- 1 intro; 2 reads on arrival
eq("the contexts read", rec().results[2].status, "done")
S.Run()                                             -- 3 bind
eq("bound in None", G.keys[KEY], "ACTIONBUTTON12")
eq("bound in the gamepad's", G.padKeys[KEY], "GAMEPADACTIONBUTTON1")
check("the originals saved", type(AltStableSyncProbeDB.contexts) == "table")
eq("read every way on arrival", rec().results[4].status, "done")
S.Next()                                            -- 5 gamepad on
S.Run()                                             -- 6 read again
S.Next()                                            -- 7 gamepad back
S.Run()                                             -- 8 put back
eq("the put-back check passes", rec().results[8].check, "PASS")
local k, p = snapshot()
check("None as before", same(k, keysBefore))
check("the gamepad's as before", same(p, padBefore))
eq("the originals cleared", AltStableSyncProbeDB.contexts, nil)
eq("never saved", saves(), 0)
eq("no errors", #errors, 0, table.concat(errors, " / "))

-- Stopped after binding: the command puts it back.
fp("steps sync contexts")
S.Next()
S.Run()                                             -- bind
eq("bound again", G.keys[KEY], "ACTIONBUTTON12")
fp("steps stop")
fp("sync contexts restore")
k, p = snapshot()
check("restore: None as before", same(k, keysBefore))
check("restore: the gamepad's as before", same(p, padBefore))
eq("restore: never saved", saves(), 0)
-- A second bind refuses while an earlier run isn't put back.
fp("steps sync contexts")
S.Next()
AltStableSyncProbeDB.contexts = { key = KEY, originals = {} }
S.Run()
check("an earlier run not put back: refused", (rec().results[3].errors or 0) >= 1)
eq("an earlier run not put back: nothing bound", G.keys[KEY], "JUMP")

finish("test_probe_contexts")
