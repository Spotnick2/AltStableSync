------------------------------------------------------------
-- test_probe_icons.lua - AltStableSyncProbe's `icons` procedure (#105)
--
-- `/fp steps sync icons` driven end to end through the host, against the
-- mock: it creates its own macro, edits it seven ways, reads both icons each
-- time (at once, and again a second later), and deletes it. It writes to no
-- other macro and refuses to start over a macro of its name.
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
            Kit.skip("test_probe_icons", "no ForeverProbe checkout; probe tests run locally")
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

G.setup{
    guid = "Player-70-ICONS", class = "PRIEST",
    spells = { { id = 2061, name = "Flash Heal" } },
    macros = { { name = "Heal", body = "/cast Heal", char = true, icon = 135000 } },
    actions = {}, keys = {},
}
-- What the mock doesn't have: a name lookup, a delete the procedure may use,
-- Attack's name and icon.
function GetMacroIndexByName(name)
    for i, m in ipairs(G.char) do if m.name == name then return 120 + i end end
    for i, m in ipairs(G.account) do if m.name == name then return i end end
    return 0
end
local deleted = {}
function DeleteMacro(index)
    local i = index - 120
    deleted[#deleted + 1] = G.char[i] and G.char[i].name
    table.remove(G.char, i)
end
C_Spell.GetSpellName = function(id) return id == 6603 and "Attack" or nil end
C_Spell.GetSpellTexture = function(id) return id == 6603 and 135641 or nil end

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
local function rec() return ForeverProbeDB.steps.records["AltStableSyncProbe/icons"] end
local function probeMacro()
    for _, m in ipairs(G.char) do if m.name == NS._measure.ICON_PROBE then return m end end
end
-- A wait step: a second goes by, then the host polls it.
local function second()
    S.Poll()                                        -- the wait starts its clock
    WoW.clock = WoW.clock + 1.5
    S.Poll()
end

check("the procedure is registered", NS._measure and #NS._measure.ISTEPS == 18, NS._measure and #NS._measure.ISTEPS)

-- A macro of its name already there: never edited, the start refuses.
table.insert(G.char, { name = NS._measure.ICON_PROBE, body = "/the owner's own", icon = 135000 })
G.sortMacros()
fp("steps sync icons")
S.Next()                                            -- 1: intro; 2 runs on arrival
eq("an existing macro of that name: the check stays", rec().at, 2)
check("an existing macro of that name: an error, not a pass", (rec().results[2].errors or 0) >= 1)
eq("an existing macro of that name: untouched", probeMacro() and probeMacro().body, "/the owner's own")
fp("steps stop")
for i, m in ipairs(G.char) do if m.name == NS._measure.ICON_PROBE then table.remove(G.char, i) end end

-- The run.
errors = {}
fp("steps sync icons")
S.Next()
eq("the check passes on arrival", rec().at, 3)
local labels = { "a", "b", "c", "d", "e", "f", "g" }
for k, label in ipairs(labels) do
    local runAt = 1 + 2 * k
    S.Run()
    eq("case " .. label .. ": ran", rec().results[runAt].status, "done")
    second()
    eq("case " .. label .. ": read again", rec().results[runAt + 1].status, "done")
    check("case " .. label .. ": the macro exists", probeMacro() ~= nil)
    -- The icon each case leaves (the mock's chosen icon).
    local want = ({ d = 134414, e = 134414, f = 134400, g = "INV_Misc_QuestionMark" })[label]
    if want then eq("case " .. label .. ": icon", probeMacro() and probeMacro().icon, want) end
end
eq("errors along the way", #errors, 0, table.concat(errors, " / "))
S.Run()                                             -- delete
eq("deleted", probeMacro(), nil)
eq("the delete check passes", rec().results[17].check, "PASS")
-- Only its own macro was ever deleted, and the owner's Heal is untouched.
for _, name in ipairs(deleted) do eq("deleted only its own", name, NS._measure.ICON_PROBE) end
local heal
for _, m in ipairs(G.char) do if m.name == "Heal" then heal = m end end
check("the other macro untouched", heal and heal.body == "/cast Heal" and heal.icon == 135000)

finish("test_probe_icons")
