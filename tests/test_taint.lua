------------------------------------------------------------
-- test_taint.lua - never reassign a Blizzard global from addon code
--
-- Assigning a global Blizzard owns marks it tainted by this addon; secure code
-- that later reads it runs tainted and its protected calls are blocked and
-- BLAMED ON US. Measured on 70235: `SlashCmdList = SlashCmdList or {}` in
-- Core.lua made a /tm raid-marker macro raise
--   ADDON_ACTION_FORBIDDEN AddOn 'AltStableSync' ... 'SetRaidTarget()'
-- Writing a field (SlashCmdList.FOO = fn) is the supported pattern.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")

-- Behaviour: loading Core leaves the SlashCmdList table itself untouched.
do
    WoW.reset()
    local blizzard = {}
    SlashCmdList = blizzard
    assert(loadfile("Core.lua"))("AltStableSync", {})
    check("Core keeps Blizzard's SlashCmdList table", rawequal(SlashCmdList, blizzard))
    check("Core registers its command as a field", type(blizzard.ALTSTABLESYNC) == "function")
end

-- Source scan: no shipped file assigns a protected-path Blizzard global.
local BLIZZARD_GLOBALS = { "SlashCmdList", "UISpecialFrames", "StaticPopupDialogs",
                           "DEFAULT_CHAT_FRAME", "ChatFrame_AddMessageEventFilter" }

local function read(path)
    local h = io.open(path, "rb"); if not h then return nil end
    local s = h:read("*a"); h:close(); return s
end

local function shippedLua()
    local toc = read("AltStableSync.toc") or ""
    local files = {}
    for line in (toc .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line:match("%.lua$") and not line:find("^#") and not line:find("^Libs") then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files
end

local scanned = 0
for _, path in ipairs(shippedLua()) do
    local src = read(path)
    if src then
        scanned = scanned + 1
        local n = 0
        for line in (src .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            local code = line:gsub("%-%-.*$", "")
            for _, g in ipairs(BLIZZARD_GLOBALS) do
                -- `G =` or `G=` at statement start; `G.x =` / `G[x] =` are fine.
                if code:match("^%s*" .. g .. "%s*=[^=]") then
                    check(("%s:%d does not reassign %s"):format(path, n, g), false, line)
                end
            end
        end
    end
end
check("scanned shipped Lua files", scanned > 0)

finish("test_taint")
