------------------------------------------------------------
-- test_minimap.lua - the minimap button, the addon-list entry and the key
-- binding (#62): they only open the window, and save only their own
-- position and visibility, into usable data only.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, P, M

-- The client's minimap and tooltip, as far as the button uses them.
local function clientFrames()
    Minimap = NewWidget("Frame", "Minimap")
    Minimap.width, Minimap.height = 198, 198
    function Minimap:GetFrameLevel() return 2 end
    function Minimap:GetCenter() return 500, 400 end
    function Minimap:GetEffectiveScale() return 1 end
    GameTooltip = { lines = {}, shown = false }
    function GameTooltip:SetOwner(owner) self.owner, self.lines = owner, {} end
    function GameTooltip:AddLine(t) self.lines[#self.lines + 1] = tostring(t) end
    function GameTooltip:Show() self.shown = true end
    function GameTooltip:Hide() self.shown = false end
    GetCursorPosition = function() return WoW.cursorX or 0, WoW.cursorY or 0 end
end

local function boot(db, char, noLogin)
    WoW.reset()
    clientFrames()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Preview.lua", "Commands.lua", "Panel.lua", "Minimap.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    AltStableSyncDB, AltStableSyncChar = db, char
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    P, M = A.Panel, A.MinimapButton
    G.setup{ class = "PRIEST", guid = "Player-70-MAIN", spells = { { id = 9472, name = "Flash Heal" } },
             actions = { [1] = { spell = 9472 } }, keys = { ["1"] = "ACTIONBUTTON1" } }
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
    if not noLogin then WoW.fire("PLAYER_LOGIN") end
end

local function button() return M._Button() end
local function point() return button():GetPoint(1) end
local function near(a, b) return math.abs(a - b) < 0.01 end
local function lines() return table.concat(GameTooltip.lines, " | ") end

local function ser(v, seen)
    if type(v) ~= "table" then return type(v):sub(1, 1) .. tostring(v) end
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. ser(v[k], seen) end
    seen[v] = nil
    return "{" .. table.concat(out, ",") .. "}"
end

-- At login: one button on the minimap, at the default angle on its edge.
do
    boot()
    local b = button()
    check("button made at login", b ~= nil and b.parent == Minimap)
    local _, rel, _, x, y = point()
    check("anchored on the minimap", rel == Minimap)
    local r = 99 + 10                                         -- half of 198, plus the clearance
    check("default angle 200 on the ellipse", near(x, r * math.cos(math.rad(200))) and near(y, r * math.sin(math.rad(200))),
          tostring(x) .. "," .. tostring(y))
    check("follows the minimap's size (a hook, not a SetScript)",
          b._followsResize == true and Minimap.hooks and #Minimap.hooks.OnSizeChanged == 1 and Minimap.scripts.OnSizeChanged == nil)
    eq("nothing saved at login", AltStableSyncDB.minimap, nil)
    check("the binding's text is set", BINDING_NAME_ALTSTABLESYNC_TOGGLE == "Open or close AltStableSync")
    -- Resized: it follows.
    Minimap.width = 300
    Minimap.hooks.OnSizeChanged[1](Minimap)
    _, _, _, x = point()
    check("resize repositions", near(x, (150 + 10) * math.cos(math.rad(200))), tostring(x))
end

-- Clicks: left opens or closes; right opens Backups from every state.
do
    boot()
    local b = button()
    check("right-click, never opened: no frame yet", P._Frame() == nil)
    b:Click("RightButton")
    check("right-click from never-created: shown", P._Frame() and P._Frame():IsShown())
    eq("right-click from never-created: on Backups", P.view, "backups")
    b:Click("LeftButton")
    check("left-click closes", not P._Frame():IsShown())
    b:Click("RightButton")
    check("right-click from hidden: shown on Backups", P._Frame():IsShown() and P.view == "backups")
    P.Hide(); P.Show()
    eq("Show still starts on Loadouts", P.view, "loadouts")
    b:Click("RightButton")
    check("right-click from shown: switches to Backups", P._Frame():IsShown() and P.view == "backups")
    P.Hide()
    b:Click("LeftButton")
    check("left-click opens", P._Frame():IsShown())
    eq("left-click opens on Loadouts", P.view, "loadouts")
    P.Hide()
end

-- Drag: the angle is saved and the button follows; drag stop ends it.
do
    boot()
    local b = button()
    b.scripts.OnDragStart(b)
    WoW.cursorX, WoW.cursorY = 500, 600                       -- straight above the centre: 90 degrees
    b.scripts.OnUpdate(b)
    check("drag saves the angle", AltStableSyncDB.minimap and near(AltStableSyncDB.minimap.angle, 90),
          ser(AltStableSyncDB.minimap))
    local _, _, _, x, y = point()
    check("drag moves the button", near(x, 0) and near(y, 109))
    b.scripts.OnDragStop(b)
    check("drag stop ends the updates", b.scripts.OnUpdate == nil)
end

-- Saved settings come back at login.
do
    boot({ schema = 9, presets = {}, backups = {}, minimap = { angle = 0, hide = true } }, { schema = 9 })
    local b = button()
    check("saved hide: hidden at login", not b:IsShown())
    local _, _, _, x, y = point()
    check("saved angle: placed at login", near(x, 109) and near(y, 0))
    -- A broken angle falls back to the default rather than erroring.
    boot({ schema = 9, presets = {}, backups = {}, minimap = { angle = "x" } }, { schema = 9 })
    _, _, _, x = point()
    check("non-number angle: default", near(x, 109 * math.cos(math.rad(200))))
end

-- /altsync minimap: hidden at once and saved, and back.
do
    boot()
    WoW.chatLines = {}
    A.SlashHandler("minimap")
    check("hidden", not button():IsShown())
    eq("hide saved", AltStableSyncDB.minimap and AltStableSyncDB.minimap.hide, true)
    check("says how to bring it back", table.concat(WoW.chat(), " "):find("/altsync minimap shows it again", 1, true) ~= nil)
    A.SlashHandler("minimap")
    check("shown again", button():IsShown())
    eq("hide cleared", AltStableSyncDB.minimap.hide, nil)
end

-- The addon list: the same clicks; the tooltip without the drag hint.
do
    boot()
    AltStableSync_OnAddonCompartmentClick("AltStableSync", "LeftButton")
    check("addon list: left opens", P._Frame() and P._Frame():IsShown())
    AltStableSync_OnAddonCompartmentClick("AltStableSync", "RightButton")
    eq("addon list: right opens Backups", P.view, "backups")
    P.Hide()
    local row = NewWidget("Button")
    AltStableSync_OnAddonCompartmentEnter("AltStableSync", row)
    check("addon list: tooltip on the row", GameTooltip.shown and GameTooltip.owner == row)
    check("addon list: no drag hint", not lines():find("Drag", 1, true), lines())
    check("addon list: says what clicks do", lines():find("Right-click: backups", 1, true) ~= nil)
    AltStableSync_OnAddonCompartmentLeave()
    check("addon list: hidden on leave", not GameTooltip.shown)
end

-- The tooltip: the save target and the Link state, in the panel's words.
do
    boot()
    local b = button()
    b.scripts.OnEnter(b)
    check("tooltip: no target yet", lines():find("No save target yet", 1, true) ~= nil, lines())
    check("tooltip: drag hint on the button", lines():find("Drag: move around the minimap", 1, true) ~= nil)
    check("tooltip: no Link line without the Link addon", not lines():find("Link", 1, true) and not lines():find("account", 1, true))
    local e = assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Raid" }, A.Loadout.Capture()))
    A.char.loaded = { loadout = { id = e.id, version = e.version } }
    b.scripts.OnEnter(b)
    check("tooltip: the target", lines():find("Save target: Raid - Holy", 1, true) ~= nil, lines())
    local peers = {}
    A.Link = { sync = { Peers = function() return peers end }, lib = { IsEnabled = function() return true end } }
    b.scripts.OnEnter(b)
    check("tooltip: offline", lines():find("Other account offline", 1, true) ~= nil, lines())
    peers = { {} }
    b.scripts.OnEnter(b)
    check("tooltip: online", lines():find("Other account online", 1, true) ~= nil, lines())
    A.Link = { why = "no peers yet" }
    b.scripts.OnEnter(b)
    check("tooltip: Link off", lines():find("Link off", 1, true) ~= nil, lines())
    A.Link = nil
    b.scripts.OnLeave(b)
    check("tooltip: hidden on leave", not GameTooltip.shown)
end

-- Nothing it does writes game state or the catalog.
do
    boot()
    local e = assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Keep" }, A.Loadout.Capture()))
    local catalog, char = ser(AltStableSyncDB.presets), ser(AltStableSyncChar)
    G.calls = {}
    local b = button()
    b:Click("LeftButton"); b:Click("RightButton"); b:Click("LeftButton")
    b.scripts.OnEnter(b); b.scripts.OnLeave(b)
    AltStableSync_OnAddonCompartmentClick("AltStableSync", "LeftButton")
    AltStableSync_OnAddonCompartmentEnter("AltStableSync", NewWidget("Button"))
    P.Toggle(); P.Toggle()                                    -- what the key binding runs
    eq("no game write", #G.calls, 0)
    eq("catalog unchanged", ser(AltStableSyncDB.presets), catalog)
    eq("character data unchanged", ser(AltStableSyncChar), char)
    check("entry still there", A.Catalog.Get(e.id) ~= nil)
    P.Hide()
end

-- Refused data: the button still opens the window (which says why); nothing
-- is read or written, and /altsync minimap is refused first.
do
    local db = { schema = 99, presets = {}, minimap = { angle = 10 } }
    local char = { schema = 9 }
    local dbBefore, charBefore = ser(db), ser(char)
    boot(db, char)
    local b = button()
    check("refused: button still made", b ~= nil)
    local _, _, _, x = point()
    check("refused: default angle (refused data not read)", near(x, 109 * math.cos(math.rad(200))))
    b:Click("LeftButton")
    check("refused: the window says why", P._Frame():IsShown() and P._W.blocked:IsShown())
    b.scripts.OnDragStart(b)
    WoW.cursorX, WoW.cursorY = 500, 600
    b.scripts.OnUpdate(b)
    b.scripts.OnDragStop(b)
    b.scripts.OnEnter(b)
    check("refused: tooltip says unsupported", lines():find("Unsupported version", 1, true) ~= nil, lines())
    WoW.chatLines = {}
    A.SlashHandler("minimap")
    check("refused: slash refuses", table.concat(WoW.chat(), " "):find("disabled", 1, true) ~= nil)
    check("refused: button still shown", b:IsShown())
    eq("refused: DB byte for byte", ser(AltStableSyncDB), dbBefore)
    eq("refused: char byte for byte", ser(AltStableSyncChar), charBefore)
    P.Hide()
end

finish("test_minimap")
