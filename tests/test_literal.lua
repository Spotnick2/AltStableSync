------------------------------------------------------------
-- test_literal.lua - saved text shown as typed, never as markup (#75)
--
-- Stored text is WoW text: a typed "|" is stored as "||", which the client
-- draws as one "|" (measured, 70338). Display neutralises unpaired pipes
-- (ASS.Literal); macro text is code and shows every pipe (ASS.Code). The
-- promises, each checked:
--   * a crafted name, `from`, character, category, spell, macro and pet
--     name reaches each place it is shown, with no markup able to render;
--   * our own colours stay; stored data and preview options never change;
--   * edit boxes are prefilled in the client's typed form.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, P, W

local NAME = "|cffff0000NAMEX|r"
local LINK = "|Hitem:6948|h[LINKX]|h"
local TEX = "|TInterface\\Icons\\INV_Misc_QuestionMark:16|tTEXX"
local MAC = "|cffff0000MACX|r"
local BODY = "/say |cffff0000BODYX|r a||b"

local function tooltip()
    GameTooltip = { lines = {} }
    function GameTooltip:SetOwner(owner) self.owner, self.lines = owner, {} end
    function GameTooltip:AddLine(t) self.lines[#self.lines + 1] = tostring(t) end
    function GameTooltip:SetText(t) self.lines = { tostring(t) } end
    function GameTooltip:Show() end
    function GameTooltip:Hide() end
    Minimap = NewWidget("Frame", "Minimap")
    function Minimap:GetCenter() return 500, 400 end
    function Minimap:GetEffectiveScale() return 1 end
    function Minimap:GetFrameLevel() return 2 end
end

local function boot()
    WoW.reset()
    tooltip()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Envelope.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Share.lua", "Preview.lua", "Commands.lua", "Panel.lua", "Minimap.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    P, W = A.Panel, A.Panel._W
    G.setup{
        class = "PRIEST", guid = "Player-70-MAIN",
        spells = { { id = 9472, name = "Flash Heal" } },
        macros = { { name = MAC, body = "/say old", char = true } },
        actions = { [1] = { spell = 9472 }, [5] = { macro = MAC } },
        keys = { ["1"] = "ACTIONBUTTON1" },
    }
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

local function ser(v)
    if type(v) ~= "table" then return type(v):sub(1, 1) .. tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. ser(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end
local function copy(v) return A.Catalog.Copy(v) end

-- The pipes right before position i, and right after position j.
local function runBefore(s, i) local n = 0; while i - n - 1 >= 1 and s:sub(i - n - 1, i - n - 1) == "|" do n = n + 1 end return n end
local function runAfter(s, j) local n = 0; while s:sub(j + n + 1, j + n + 1) == "|" do n = n + 1 end return n end

-- Every hostile marker in `s` sits after (and before) an even run of pipes.
local MARKERS = { { "cffff0000NAMEX", "r" }, { "cffff0000MACX", "r" }, { "cffff0000BODYX", "r" },
                  { "Hitem:6948", "h[LINKX]" }, { "h[LINKX]", "h" }, { "TInterface", "tTEXX" } }
local function inert(s)
    for _, m in ipairs(MARKERS) do
        local from = 1
        while true do
            local i, j = s:find(m[1], from, true)
            if not i then break end
            if runBefore(s, i) % 2 == 1 then return false, m[1] end
            from = j + 1
        end
    end
    -- "|r" after a payload, "|h" after a link, "|t" before TEXX.
    for _, p in ipairs({ "NAMEX", "MACX", "BODYX", "%[LINKX%]", ":16" }) do
        for j in s:gmatch(p .. "()") do
            if runAfter(s, j - 1) % 2 == 1 then return false, p end
        end
    end
    return true
end
local function everything()
    local all = {}
    for _, t in ipairs(WoW.chatLines) do all[#all + 1] = t end
    for _, t in ipairs(WoW.drawn) do all[#all + 1] = t end
    for _, t in ipairs(GameTooltip.lines or {}) do all[#all + 1] = t end
    return all
end
local function said(s) return table.concat(WoW.chat(), "\n"):find(s, 1, true) ~= nil end
local function shownBody() return _G.AltStableSyncPreview and _G.AltStableSyncPreview.body:GetText() or "" end
local function shownTitle() return _G.AltStableSyncPreview and _G.AltStableSyncPreview.title:GetText() or "" end
local function visible()
    local out = {}
    for _, b in ipairs(W.menu.items) do if b:IsShown() then out[#out + 1] = b end end
    return out
end
local function pick(owner, value)
    owner:Click()
    for _, b in ipairs(visible()) do if b.value == value then return b:Click() end end
    error("no menu item " .. tostring(value))
end

------------------------------------------------------------
-- Literal and Code themselves
------------------------------------------------------------
do
    boot()
    local L, C = A.Literal, A.Code
    eq("literal: a typed pipe is unchanged", L("a||b"), "a||b")
    eq("literal: a lone pipe is doubled", L("a|b"), "a||b")
    eq("literal: an odd run gets one more", L("|||c"), "||||c")
    eq("literal: colour neutralised", L("|cffff0000X|r"), "||cffff0000X||r")
    eq("literal: plain text unchanged", L("Raid Heals: 2/3 (ok)"), "Raid Heals: 2/3 (ok)")
    eq("literal: other bytes unchanged", L("a\1b"), "a\1b")
    eq("literal: idempotent", L(L("|a||b|||c")), L("|a||b|||c"))
    eq("code: every pipe doubled", C('print("a|b")'), 'print("a||b")')
    eq("code: a pair doubled too", C('print("a||b")'), 'print("a||||b")')
    eq("share's literal is the same", A.Share.Literal("|c"), "||c")
end

------------------------------------------------------------
-- A crafted entry, everywhere it is shown
------------------------------------------------------------
local function crafted()
    local m = assert(A.Loadout.Capture())
    m.actions[2] = { kind = "spell", id = 99999, name = "Bolt " .. LINK, policy = "highest", class = true }
    m.actions[5] = { kind = "macro", name = MAC, body = BODY, scope = "char" }
    m.macros = { [MAC] = { body = BODY } }
    local slots = {}
    for i = 1, 10 do slots[i] = false end
    m.pet = { [7] = { family = "Cat " .. TEX, slots = slots } }
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Raid " .. NAME,
        provenance = { sourceChar = "Alt" .. LINK, build = "70338" } }, m))
end

do
    boot()
    local e = crafted()
    -- A loadout in a category a newer build sent, and a conflict copy.
    local odd = copy(e); odd.id = "loadout-ffffffffffff-1"; odd.version = "ffffffffffff:1"; odd.category = "zz" .. TEX
    odd.name = "Odd"; odd.ancestors = {}; odd.previous = nil
    assert(A.Catalog.Upsert(odd, "Other-Realm"))
    local mine = assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Mine" }, A.Loadout.Capture()))
    local theirs = copy(mine); theirs.version = "eeeeeeeeeeee:4"; theirs.parent = "eeeeeeeeeeee:3"; theirs.ancestors = {}
    theirs.modules.actions[3] = { kind = "item", id = 5512 }
    eq("a conflict copy", A.Catalog.Upsert(theirs, "Other" .. NAME), "conflict")
    local stored = ser(AltStableSyncDB.presets)
    local before = {}
    for id, x in pairs(AltStableSyncDB.presets) do if id ~= e.id then before[id] = ser(x) end end

    -- Chat: list, conflicts.
    A.Commands.list()
    check("list: the name reaches chat", said("NAMEX"))
    A.Commands.conflicts()
    check("conflicts: the from reaches chat", table.concat(WoW.chat(), "\n"):find("NAMEX", 1, true) ~= nil)
    check("chat: our prefix keeps its colour", WoW.chat()[1]:find("|cff00ccff[AltStableSync]|r ", 1, true) == 1)

    -- The Load preview, shown twice from the same options.
    A.Commands.LoadEntry(e)
    local opts = A.Preview.Shown()
    check("load: previewed", opts ~= nil)
    local lines = ser(opts.lines)
    check("load: the title holds the name", shownTitle():find("NAMEX", 1, true) ~= nil, shownTitle())
    check("load: the macro diff holds the body", shownBody():find("BODYX", 1, true) ~= nil, shownBody())
    check("load: the waiting spell is named", shownBody():find("LINKX", 1, true) ~= nil, shownBody())
    check("load: the other pet is named", shownBody():find("TEXX", 1, true) ~= nil, shownBody())
    check("load: the macro is named", shownBody():find("MACX", 1, true) ~= nil, shownBody())
    local first = shownBody()
    A.Preview.Show(opts)
    eq("load: shown again, the same", shownBody(), first)
    eq("load: options unchanged", ser(opts.lines), lines)
    -- The macro diff's body is code: every pipe doubled.
    check("load: the diff shows every pipe", first:find("||cffff0000BODYX||r a||||b", 1, true) ~= nil, first)
    _G.AltStableSyncPreview.confirm:Click()

    -- Delete and Resolve previews.
    A.Commands.DeleteEntry(e.id)
    check("delete: the title holds the name", shownTitle():find("NAMEX", 1, true) ~= nil)
    _G.AltStableSyncPreview.cancel:Click()
    A.Commands.ResolveCopy(theirs.id .. "~" .. theirs.version, "theirs")
    check("resolve: the from is named", shownBody():find("NAMEX", 1, true) ~= nil, shownBody())
    _G.AltStableSyncPreview.cancel:Click()

    -- The panel, the save target and its status.
    P.Show()
    pick(W.cat, "holy")
    pick(W.entry, e.id)
    P.Refresh()
    check("panel: the picker shows the name", W.entry.label:GetText():find("NAMEX", 1, true) ~= nil)
    check("panel: the box title (upper case)", W.boxTitle:GetText():find("NAMEX", 1, true) ~= nil, W.boxTitle:GetText())
    check("panel: saved by", W.boxFoot:GetText():find("LINKX", 1, true) ~= nil, W.boxFoot:GetText())
    check("panel: the target line", W.target:GetText():find("NAMEX", 1, true) ~= nil, W.target:GetText())
    check("panel: our gold stays", W.target:GetText():find("|cffffd100Save target:|r", 1, true) == 1)
    W.cat:Click()
    local catText
    for _, b in ipairs(visible()) do if b.value == odd.category then catText = b.text:GetText() end end
    W.menu:Hide()
    check("panel: the unknown category is listed", catText and catText:find("TEXX", 1, true) ~= nil, tostring(catText))
    -- The target changes on the other account: the status names it.
    assert(A.Catalog.Rename(e.id, "Raid " .. NAME .. " 2", A.Catalog.Get(e.id).version))
    P.RefreshSave()
    check("panel: the save status names it", W.saveStatus:GetText():find("NAMEX", 1, true) ~= nil, W.saveStatus:GetText())
    check("panel: so does Save's tooltip", (W.save.why or ""):find("NAMEX", 1, true) ~= nil, tostring(W.save.why))
    -- The footer repeats a command's message.
    A.Commands.list()
    P.Refresh()
    check("panel: the footer", W.status:GetText():find("NAMEX", 1, true) ~= nil, W.status:GetText())
    -- The minimap tooltip.
    A.MinimapButton.Tooltip(GameTooltip)
    check("minimap: the target", table.concat(GameTooltip.lines, "\n"):find("NAMEX", 1, true) ~= nil)
    -- Rename, Share and Import.
    pick(W.manage, "rename")
    check("rename: the title", P._Dialog().title:GetText():find("NAMEX", 1, true) ~= nil)
    P._Dialog():Hide()
    P._ShowShare(A.Catalog.Get(e.id))
    check("share: the title", P._Share().title:GetText():find("NAMEX", 1, true) ~= nil)
    P._Share():Hide()
    local x = { kind = "loadout", class = "PRIEST", category = "holy", name = NAME, modules = A.Loadout.Capture() }
    P.OpenImport()
    WoW.type(P._Import().box, assert(A.Envelope.EncodeShare(x)))
    WoW.tick(0.4)
    check("import: the status", P._Import().status:GetText():find("NAMEX", 1, true) ~= nil, P._Import().status:GetText())
    P._Import():Hide()

    -- Nothing anywhere could render.
    local n, bad = 0, nil
    for _, s in ipairs(everything()) do
        n = n + 1
        local ok, which = inert(s)
        if not ok then bad = bad or (which .. " in: " .. s) end
    end
    check("nothing drawn or printed renders markup (" .. n .. " strings)", bad == nil, bad)
    -- Showing changed nothing stored: the other entries are byte-identical,
    -- and the renamed one kept its crafted text raw.
    local p = AltStableSyncDB.presets
    for id, was in pairs(before) do eq("stored: " .. id .. " unchanged", ser(p[id]), was) end
    check("stored: the crafted text raw", p[e.id].name == "Raid " .. NAME .. " 2"
        and p[e.id].modules.macros[MAC].body == BODY and p[e.id].provenance.sourceChar == "Alt" .. LINK)
    check("stored: before the rename, raw too", stored:find("Raid |cffff0000NAMEX|r", 1, true) ~= nil)
end

------------------------------------------------------------
-- Edit boxes: the client's typed form
------------------------------------------------------------
do
    boot()
    local typed = assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "a||b" }, A.Loadout.Capture()))
    local odd = assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "c|d" }, A.Loadout.Capture()))
    P.Show()
    pick(W.cat, "holy")
    pick(W.entry, typed.id)
    pick(W.manage, "rename")
    eq("rename: a typed name prefills as typed", P._Dialog().name:GetText(), "a||b")
    P._Dialog():Hide()
    eq("cancel: unchanged", A.Catalog.Get(typed.id).name, "a||b")
    pick(W.entry, odd.id)
    pick(W.manage, "rename")
    eq("rename: a crafted name prefills neutralised", P._Dialog().name:GetText(), "c||d")
    -- Confirming with the prefill left alone stores the typed form.
    WoW.type(P._Dialog().name, "c||d")
    P._Dialog().review:Click()
    _G.AltStableSyncPreview.confirm:Click()
    eq("rename confirmed: the typed form", A.Catalog.Get(odd.id).name, "c||d")
    -- Import: the same prefill; confirming stores it.
    local x = { kind = "loadout", class = "PRIEST", category = "shadow", name = "e|f", modules = A.Loadout.Capture() }
    P.OpenImport()
    WoW.type(P._Import().box, assert(A.Envelope.EncodeShare(x)))
    WoW.tick(0.4)
    eq("import: the name prefills neutralised", P._Import().name:GetText(), "e||f")
    P._Import().review:Click()
    _G.AltStableSyncPreview.confirm:Click()
    local got
    for _, z in pairs(AltStableSyncDB.presets) do if z.category == "shadow" then got = z end end
    eq("import confirmed: the typed form", got and got.name, "e||f")
end

------------------------------------------------------------
-- Macro code in the Import preview: one pipe and two stay distinct
------------------------------------------------------------
do
    boot()
    local m = assert(A.Loadout.Capture())
    m.macros = { One = { body = '/run print("a|b")' }, Two = { body = '/run print("a||b")' } }
    m.actions[7] = { kind = "macro", name = "One", body = m.macros.One.body, scope = "char" }
    m.actions[8] = { kind = "macro", name = "Two", body = m.macros.Two.body, scope = "char" }
    A.Commands.ImportEntry({ class = "PRIEST", category = "holy", name = "Code", modules = m })
    local body = shownBody()
    check("code: one pipe", body:find('/run print("a||b")', 1, true) ~= nil, body)
    check("code: two pipes", body:find('/run print("a||||b")', 1, true) ~= nil, body)
end

finish("test_literal")
