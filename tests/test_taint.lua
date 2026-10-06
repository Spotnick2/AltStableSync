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

local BLIZZARD_GLOBALS = { "SlashCmdList", "UISpecialFrames", "StaticPopupDialogs",
                           "DEFAULT_CHAT_FRAME", "ChatFrame_AddMessageEventFilter" }
local PROTECTED = {}
for _, g in ipairs(BLIZZARD_GLOBALS) do PROTECTED[g] = true end

-- Behaviour: load a chunk in an environment that records every write to a
-- Blizzard global, however it is spelled - `G =`, `_G.G =`, rawset(_G, ...),
-- multi-assignment, inside a branch. Same-table writes count: WoW taints the
-- global SLOT on any addon write, so table identity proves nothing.
local function WritesOf(chunk)
    local writes = {}
    local env = setmetatable({}, { __index = _G, __newindex = function(t, k, v)
        if PROTECTED[k] then writes[#writes + 1] = k end
        rawset(t, k, v)
    end })
    env._G = env
    env.rawset = function(t, k, v)
        if t == env and PROTECTED[k] then writes[#writes + 1] = k end
        return rawset(t, k, v)
    end
    setfenv(chunk, env)
    chunk("AltStableSync", {})
    return writes, env
end

do
    WoW.reset()
    local writes, env = WritesOf(assert(loadfile("Core.lua")))
    check("Core writes no Blizzard global", #writes == 0, table.concat(writes, ","))
    check("Core registers its command as a field", type(SlashCmdList.ALTSTABLESYNC) == "function"
        and rawget(env, "SlashCmdList") == nil)
end

-- The recorder itself must catch every spelling (mutation check, in memory).
for _, src in ipairs({
    "SlashCmdList = SlashCmdList or {}",
    "_G.SlashCmdList = SlashCmdList",
    "rawset(_G, 'SlashCmdList', SlashCmdList)",
    "local a; a, SlashCmdList = 1, SlashCmdList",
    "if true then SlashCmdList = SlashCmdList end",
}) do
    local writes = WritesOf(assert(loadstring(src)))
    check("recorder catches: " .. src, #writes == 1)
end
check("recorder allows a field write", #WritesOf(assert(loadstring("SlashCmdList.X = function() end"))) == 0)

-- Source scan, as a second net: addon-owned Lua listed directly in the TOC
-- (libraries excluded) never assigns a protected-path Blizzard global at
-- statement start. Every listed file must be readable - a skipped file would
-- silently prove nothing.

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
    check("listed file is readable: " .. path, src ~= nil)
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
