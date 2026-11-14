------------------------------------------------------------
-- test_methods.lua - every widget method the addon calls exists on Forever
--
-- The stub answers a widget method the build lacks with nothing at all, so a
-- call Forever doesn't have would pass silently. The addon is exercised as
-- widely as is cheap (every TOC file loaded, every event, a few seconds of
-- frames and timers, the window and every view of it, a hover on everything,
-- the dialogs, the preview, the prompts, the minimap button, every slash
-- command), then WowTestKit's Kit.checkMethods checks each recorded
-- "Type:Method" against the pinned build's widget methods
-- (tests/kit.pin, data/forever-<build>/).
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
dofile("tests/wow_game.lua")
dofile("tests/wow_ui.lua")

local G = WoW.game

-- The client's minimap and tooltip, as far as the addon uses them.
Minimap = CreateFrame("Frame", "Minimap")
Minimap:SetSize(198, 198)
function Minimap:GetFrameLevel() return 2 end
function Minimap:GetCenter() return 500, 400 end
function Minimap:GetEffectiveScale() return 1 end
GameTooltip = CreateFrame("GameTooltip", "GameTooltip")

WoW.reset()
WoW.ui.setup()
G.setup{
    class = "PRIEST", guid = "Player-70-MAIN",
    spells = { { id = 2061, name = "Flash Heal", low = true }, { id = 9472, name = "Flash Heal" } },
    macros = { { name = "Shield", body = "/cast Power Word: Shield", char = true } },
    actions = { [1] = { spell = 9472 }, [3] = { item = 5512 }, [4] = { macro = "Shield" } },
    items = { [5512] = 3 },
    keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" },
}

-- Every file the TOC loads, in its order (the libraries' .xml lines are the
-- packager's: LibStub is the one .lua among them).
local tocFiles = Kit.tocFiles("AltStableSync.toc")
for _, f in ipairs(tocFiles) do assert(loadfile(f))("AltStableSync", {}) end
check("every TOC file loaded", #tocFiles >= 18, #tocFiles .. " files")

WoW.fire("ADDON_LOADED", "AltStableSync")
local A = AltStableSync
WoW.fireAllRegistered()
WoW.fire("PLAYER_ENTERING_WORLD", true, false)
for _ = 1, 5 do WoW.tick(1) end
WoW.clock = WoW.clock + 10

-- Every frame under f, depth first.
local function walk(f, fn)
    fn(f)
    for _, c in ipairs(f._children or {}) do walk(c, fn) end
end
-- Hover everything that answers a hover (tooltips, hints).
local function hover(frame)
    walk(frame, function(w)
        local s = w._scripts
        if s.OnEnter then s.OnEnter(w) end
        if s.OnLeave then s.OnLeave(w) end
    end)
end

-- A loadout to browse, and the window: every view, a hover on everything.
local entry = assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general", name = "Everyday" },
    assert(A.Loadout.Capture())))
local P = A.Panel
P.Show()
for _, view in ipairs({ "loadouts", "backups", "ui", "loadouts" }) do
    P.Open(view)
    for _ = 1, 3 do P._Frame()._scripts.OnUpdate(P._Frame(), 1.1) end
    hover(P._Frame())
end
for _, tab in pairs(P._W.tabs) do tab:Click() end
P.Refresh()
hover(P._Frame())
P.Hide()

-- The dialogs (name, share, import), each shown and hovered.
for _, dlg in ipairs({ P._Dialog(), P._Share(), P._Import() }) do
    dlg:Show()
    hover(dlg)
    dlg:Hide()
end
P._ShowShare(entry)
hover(P._Share())
P.OpenImport()
P.Hide()

-- The preview (with its tick box), the reload prompt, the offer.
A.Preview.Show({ title = "t", lines = { "x" }, confirm = "OK", onConfirm = function() end,
                 check = { text = "c", checked = true, onToggle = function() end } })
hover(_G.AltStableSyncPreview)
_G.AltStableSyncPreview.check:Click()
_G.AltStableSyncPreview.cancel:Click()
A.Preview.Show({ title = "t", lines = { "x" }, onConfirm = function() end })
_G.AltStableSyncPreview.confirm:Click()
A.Reload.Ask("Reload to finish.")
hover(_G.AltStableSyncReload)
A.Offer.Show(true)
for _ = 1, 3 do WoW.tick(1) end

-- The minimap button: both clicks, a drag, the tooltips, hiding it.
local button = A.MinimapButton._Button()
check("the minimap button exists", button ~= nil)
button:Click("LeftButton"); button:Click("RightButton")
button._scripts.OnDragStart(button)
WoW.cursorX, WoW.cursorY = 500, 600
button._scripts.OnUpdate(button)
button._scripts.OnDragStop(button)
button._scripts.OnEnter(button); button._scripts.OnLeave(button)
AltStableSync_OnAddonCompartmentClick("AltStableSync", "LeftButton")
AltStableSync_OnAddonCompartmentEnter("AltStableSync", CreateFrame("Button"))
AltStableSync_OnAddonCompartmentLeave()
Minimap._scripts.OnSizeChanged = nil
for _, hook in ipairs((Minimap._hooks or {}).OnSizeChanged or {}) do hook(Minimap) end

-- Every slash command.
for _, cmd in ipairs({ "", "status", "list", "backups", "backup", "conflicts", "minimap", "import", "saveas Methods",
                       "save", "load Everyday", "restore", "rename Everyday Daily", "ui", "unknown" }) do
    SlashCmdList.ALTSTABLESYNC(cmd)
    for _ = 1, 3 do WoW.tick(1) end
    if _G.AltStableSyncPreview and A.Preview.Shown() then _G.AltStableSyncPreview.cancel:Click() end
end

-- Each recorded Type:Method must exist on that widget type in the pinned
-- build. An allow entry is only for a method a Blizzard mixin adds in Lua,
-- which the dump's widget walk can't see (none today). The floor is what
-- loading and the exercise record today, rounded down: it keeps the exercise
-- from quietly shrinking.
local recorded = kit(Kit.checkMethods, {})
check("the exercise reached the windows", recorded >= 100, recorded .. " recorded")

finish("test_methods")
