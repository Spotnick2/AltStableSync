------------------------------------------------------------
-- Panel.lua - the AltStableSync window (#9): /altsync
--
-- A view and a launcher over the flows in Commands.lua. It adds no write
-- path: every button opens one of those flows' previews (Preview.lua), and
-- only a preview's confirm writes. The rules it keeps:
--   * browsing (the Category and Saved loadout pickers) and the save target
--     are separate: Load acts on the browsed entry, Save on the entry this
--     character last loaded or saved (ASS.char.loaded), and browsing never
--     changes the target;
--   * a button passes the ids and values it reads at the click (the entry id,
--     the typed name, the chosen category); the flow fixes them in its
--     preview, so changing the panel afterwards can't redirect a confirm;
--   * a redraw only updates the panel's own widgets: it never replans,
--     replaces or hides an open preview, and never writes anything;
--   * rows are display copies: catalog entries and backups are never marked
--     or sorted in place.
-- Panel.Model() and Panel.SaveStatus() are pure and tested; the frames only
-- draw them. All panel state is session-only (no SavedVariables change): the
-- window opens on the save target's category and entry.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Panel = {}
ASS.Panel = Panel

-- Session state: the view; what is browsed (category key, entry id); the
-- selected backup (the snapshot table itself, never its ring position).
-- `noDefault`: the browsed entry was removed, so say so instead of quietly
-- picking another.
Panel.view = "loadouts"
Panel.sel = { category = nil, id = nil, snap = nil, noDefault = false }

-- Seconds, only while the panel is shown. The save status is recomputed when
-- the bars, keys, macros, cursor or combat change (and after a catalog
-- write); the slow poll only catches what no event announces.
local REFRESH, SAVE_REFRESH = 1, 5
local SAVE_EVENTS = { "ACTIONBAR_SLOT_CHANGED", "UPDATE_BINDINGS", "UPDATE_MACROS", "CURSOR_CHANGED",
                      "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PET_BAR_UPDATE" }
local MESSAGE_SECONDS = 20                -- how long a command's message stays in the footer

local function PlayerClass()
    local _, class = UnitClass("player")
    return class
end

local function Count(t)
    local n = 0
    for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end
    return n
end

local function Plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function When(t)
    if type(t) ~= "number" or not date then return "?" end
    return date("%Y-%m-%d %H:%M", t)
end

local function Short(t)
    if type(t) ~= "number" or not date then return "?" end
    return date("%b %d, %H:%M", t)
end

------------------------------------------------------------
-- The model (pure)
------------------------------------------------------------

-- The Link addon's state for the footer: availability only, never "synced".
-- Reads only: it never starts an exchange. Returns text, online.
local function LinkLine()
    local Link = ASS.Link
    if not Link then return nil end
    if not Link.sync then return "Link off (" .. tostring(Link.why or "not started") .. ")", false end
    local okE, on = pcall(Link.lib.IsEnabled)
    if not (okE and on) then return "Link off", false end
    local okP, peers = pcall(Link.sync.Peers)
    local n = okP and type(peers) == "table" and #peers or 0
    if n > 0 then return "Other account online", true end
    return "Other account offline", false
end

local function EntryStatus(e)
    local Link = ASS.Link
    if not (Link and Link.EntryStatus) then return nil end
    local ok, st = pcall(Link.EntryStatus, e)
    return ok and st or nil
end

-- What a saved entry holds, as aligned rows. Counts are of saved content:
-- actions = filled saved slots; keys = key presses bound across every saved
-- command; macros = the character macros it carries.
local function Contents(e)
    local mod = e.modules
    if type(mod) ~= "table" then return nil end
    local keys = 0
    for _, list in pairs(type(mod.bindings) == "table" and mod.bindings or {}) do
        if type(list) == "table" then keys = keys + #list end
    end
    local rows = {
        { label = "Action bars", value = Plural(Count(mod.actions), "saved action") },
        { label = "Keybindings", value = Plural(keys, "saved key"),
          sub = keys > 0 and "Destination: Character" or nil },
        { label = "Macros", value = Plural(Count(mod.macros), "character macro") },
    }
    if Count(mod.pet) > 0 then rows[#rows + 1] = { label = "Pet bars", value = Plural(Count(mod.pet), "pet family") } end
    return rows
end

local function Marks(e, rec, copiesOf)
    local marks = {}
    if rec and rec.id == e.id then
        marks[#marks + 1] = rec.version == e.version and "save target" or "save target, older version"
    end
    if type(e.conflict) == "table" then
        marks[#marks + 1] = e.conflict.deletion and ("conflict: deleted on " .. tostring(e.conflict.from or "your other account"))
            or "conflict copy"
    end
    if copiesOf[e.id] then marks[#marks + 1] = "conflict" end
    local st = EntryStatus(e)
    if st then marks[#marks + 1] = st end
    return marks
end

-- Everything the panel shows. `sel` = Panel.sel. The model resolves what is
-- browsed (m.category, m.selectedId); Panel.Refresh keeps it for the session.
function Panel.Model(sel)
    sel = sel or {}
    local m = { categories = {}, entries = {}, backups = {} }
    if ASS.disabled then
        m.blocked = "Unsupported version: AltStableSync won't touch your data (" .. tostring(ASS.disabled) .. ")."
        return m
    end
    if not (ASS.db and ASS.char) then
        m.blocked = "Not initialised yet."
        return m
    end
    local class = PlayerClass()
    m.class = class
    local okR, ready = pcall(function() return ASS.Ready.IsReady() end)
    m.ready = okR and ready and true or false
    m.combat = InCombatLockdown and InCombatLockdown() and true or false
    m.link, m.online = LinkLine()
    local rec = type(ASS.char.loaded) == "table" and ASS.char.loaded.loadout or nil

    local all = class and ASS.Catalog.ListAll("loadout", class) or {}
    local copiesOf, byCat = {}, {}
    for _, e in ipairs(all) do
        if type(e.conflict) == "table" then copiesOf[e.conflict.of] = true end
        local k = tostring(e.category)
        byCat[k] = byCat[k] or {}
        table.insert(byCat[k], e)
    end
    -- Categories: the class's, then keys this build doesn't know (sent by a
    -- newer build), under their raw name.
    -- Every display string here is shown literally (#75); keys and ids stay
    -- raw. Menu items (entries, categories) are escaped where every menu
    -- draws them (DrawMenu).
    local L = ASS.Literal
    local label, unknown = {}, {}
    for _, c in ipairs(ASS.Categories.List(class) or {}) do
        label[c.key] = L(c.label)
        m.categories[#m.categories + 1] = { key = c.key, label = c.label, count = #(byCat[c.key] or {}), known = true }
    end
    for k in pairs(byCat) do if not label[k] then unknown[#unknown + 1] = k end end
    table.sort(unknown)
    for _, k in ipairs(unknown) do
        label[k] = L(k)
        m.categories[#m.categories + 1] = { key = k, label = k, count = #byCat[k], known = false }
    end
    m.noLoadouts = #all == 0

    -- The save target: what this character last loaded or saved.
    local targetEntry
    if rec then
        local e = ASS.Catalog.Get(rec.id)
        local live = e and not e.deleted and not e.conflict and e.kind == "loadout" and e.class == class
        m.target = { id = rec.id, name = e and L(e.name) or nil,
                     category = live and label[tostring(e.category)] or nil, deleted = not live,
                     older = live and e.version ~= rec.version or false }
        if live then targetEntry = e end
    end

    -- What is browsed. An entry that disappeared is said, not replaced.
    local selected = sel.id and ASS.Commands.Own(sel.id)
    if sel.id and not selected then m.selectionGone = true end
    local category = sel.category
    if not (category and label[category]) then
        category = (selected and tostring(selected.category)) or (targetEntry and tostring(targetEntry.category))
        if not category then
            for _, c in ipairs(m.categories) do if c.count > 0 then category = c.key break end end
        end
        category = category or "general"
    end
    m.category, m.categoryLabel = category, label[category] or L(category)
    local list = byCat[category] or {}
    if selected and tostring(selected.category) ~= category then selected = nil end
    if not selected and not m.selectionGone and not sel.noDefault then
        if targetEntry and tostring(targetEntry.category) == category then selected = targetEntry
        else selected = list[1] end
    end
    for _, e in ipairs(list) do
        local marks = Marks(e, rec, copiesOf)
        m.entries[#m.entries + 1] = { id = e.id, name = tostring(e.name), marks = marks,
            text = tostring(e.name) .. (#marks > 0 and ("  (" .. table.concat(marks, ", ") .. ")") or "") }
    end
    m.emptyCategory = not m.noLoadouts and #list == 0
    if selected then
        m.selectedId = selected.id
        local conflict = type(selected.conflict) == "table" and selected.conflict or nil
        local p = type(selected.provenance) == "table" and selected.provenance or {}
        m.selected = {
            id = selected.id, name = L(selected.name), contents = Contents(selected),
            marks = Marks(selected, rec, copiesOf),
            saved = ("Saved %s%s"):format(Short(selected.updated), p.sourceChar and (" by " .. L(p.sourceChar)) or ""),
            savedFull = ("Saved %s%s"):format(When(selected.updated), p.sourceChar and (" by " .. L(p.sourceChar)) or ""),
            conflictCopy = conflict ~= nil, deletion = conflict and conflict.deletion or false,
            from = conflict and L(conflict.from or "your other account") or nil,
        }
        m.targetDiffers = m.target ~= nil and m.target.id ~= selected.id
    end

    -- Backups: the incomplete operation first, the ring newest first, then
    -- the first backup.
    local ring, op, first = ASS.Backups.List()
    if op then
        m.pinned = L(op.op and op.op.name or "a loadout")
        m.backups[#m.backups + 1] = { snap = op.snapshot,
            text = ("Incomplete load of %s, %s"):format(m.pinned, When(op.snapshot and op.snapshot.at)) }
    end
    for i, s in ipairs(ring) do
        m.backups[#m.backups + 1] = { snap = s, text = ("%s, %s"):format(L(s.reason or ("Backup " .. i)), When(s.at)) }
    end
    if first then m.backups[#m.backups + 1] = { snap = first, text = "First backup, " .. When(first.at) } end
    for _, b in ipairs(m.backups) do
        if sel.snap ~= nil and b.snap == sel.snap then b.selected = true; m.backupSelected = true end
    end
    if sel.snap ~= nil and not m.backupSelected then m.backupGone = true end
    return m
end

-- The selected snapshot's slot NOW ("op", a ring index, "first"), or nil
-- when it's gone. Resolved at the click: a newer backup shifts the ring.
function Panel.SlotOf(snap)
    if snap == nil then return nil end
    local ring, op, first = ASS.Backups.List()
    if op and op.snapshot == snap then return "op" end
    for i, s in ipairs(ring) do if s == snap then return tostring(i) end end
    if first == snap then return "first" end
    return nil
end

-- The save target's status: a fresh PlanSave, which reads the live bars,
-- keybindings and cursor and writes nothing. "No unsaved changes" only when
-- that comparison found none.
local SaveStatus
function Panel.SaveStatus()
    -- Its text can name the entry (#75): shown literally, in the status line
    -- and the Save button's tooltip.
    local st = SaveStatus()
    st.text = ASS.Literal(st.text or "")
    return st
end
SaveStatus = function()
    if ASS.disabled or not (ASS.db and ASS.char) then return { ok = false, text = "" } end
    local rec = type(ASS.char.loaded) == "table" and ASS.char.loaded.loadout or nil
    if not rec then return { ok = false, text = "No save target yet: load a loadout, or use Save As." } end
    local ok, m, err = pcall(ASS.Loadout.PlanSave, false)
    if not ok then return { ok = false, text = "Can't check for changes right now." } end
    if not m then return { ok = false, text = tostring(err) } end
    if m.noop then return { ok = false, noop = true, text = "No unsaved changes." } end
    -- Everything Merge counts as a change: slots (a character macro's text or
    -- icon counts there), keys changed or added, slots it now covers, the pet
    -- bar. Anything else it found still says so.
    local parts = {}
    local slots, keys = #(m.changed or {}), #(m.keysChanged or {}) + #(m.keysAdded or {})
    if slots > 0 then parts[#parts + 1] = Plural(slots, "slot") end
    if keys > 0 then parts[#parts + 1] = Plural(keys, "key") end
    if (m.added or 0) > 0 then parts[#parts + 1] = Plural(m.added, "new slot") end
    local pet = type(m.pet) == "table" and m.pet or {}
    if #(pet.changed or {}) > 0 or pet.added then parts[#parts + 1] = "the pet bar" end
    if #parts == 0 then return { ok = true, text = "Unsaved changes: Save shows them." } end
    return { ok = true, text = "Unsaved: " .. table.concat(parts, ", ") .. " changed." }
end

-- Save As's default category: the save target's, else General. Never the
-- browsed one: the player may be saving a different setup.
function Panel.DefaultCategory()
    local class = PlayerClass()
    local rec = ASS.char and type(ASS.char.loaded) == "table" and ASS.char.loaded.loadout or nil
    local e = rec and ASS.Catalog.Get(rec.id)
    if e and not e.deleted and ASS.Categories.IsValid(class, e.category) then return e.category end
    return "general"
end

-- A command's message, kept for the footer (refusals included).
if ASS.Commands then
    ASS.Commands.onMessage = function(msg)
        Panel.message, Panel.messageAt = ASS.Literal(msg), GetTime()
        Panel.dirty = true
    end
end
-- A local catalog write: redraw on the next frame, once the call that made
-- it has finished (Save and Save As update the loaded record after it).
if ASS.Catalog and ASS.Catalog.OnLocalWrite then
    ASS.Catalog.OnLocalWrite(function() Panel.dirty, Panel.saveDirty = true, true end)
end

------------------------------------------------------------
-- Widgets: our own buttons, pickers and menu (no Blizzard menus)
------------------------------------------------------------

local frame, W = nil, {}
local WIDTH, PAD = 400, 18
-- The window's height, from its parts: above the contents box (header,
-- navigation, the two pickers), below it (Load, the save section and its
-- hint, with padding), and the footer's own reserved band.
local ABOVE_BOX, BELOW_BOX, FOOTER = 106 + 102, 198 - 6, 50
local WHITE = "Interface\\Buttons\\WHITE8X8"
local GOLD, BODY, MUTED = { 1, 0.82, 0 }, { 0.92, 0.92, 0.9 }, { 0.62, 0.62, 0.6 }

local function Cmd() return ASS.Commands end

local function Text(parent, font, width, color)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    t:SetJustifyH("LEFT")
    if width then t:SetWidth(width) end
    if color then t:SetTextColor(color[1], color[2], color[3]) end
    return t
end

local STYLE = {
    primary   = { bg = { 0.10, 0.22, 0.48, 0.95 }, edge = { 0.40, 0.60, 0.95, 1 } },
    secondary = { bg = { 0.13, 0.13, 0.15, 0.95 }, edge = { 0.42, 0.42, 0.44, 1 } },
    field     = { bg = { 0.05, 0.05, 0.07, 0.95 }, edge = { 0.42, 0.42, 0.44, 1 } },
    off       = { bg = { 0.08, 0.08, 0.08, 0.80 }, edge = { 0.28, 0.28, 0.28, 1 } },
}

local function Paint(b)
    local s = b:IsEnabled() and STYLE[b.kind] or STYLE.off
    if b.SetBackdropColor then
        b:SetBackdropColor(s.bg[1], s.bg[2], s.bg[3], s.bg[4])
        b:SetBackdropBorderColor(s.edge[1], s.edge[2], s.edge[3], s.edge[4])
    end
end

-- Enable or disable, with the reason a disabled button shows on hover.
local function Set(b, on, why)
    if on then b:Enable() else b:Disable() end
    b.why = not on and why or nil
    Paint(b)
end

local function Tip(owner, text)
    if not (GameTooltip and text and text ~= "") then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

-- kind: "primary" (one per section) or "secondary".
local function GButton(parent, text, width, kind)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width, 26)
    b.kind = kind or "secondary"
    if b.SetBackdrop then b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }) end
    b:SetNormalFontObject("GameFontHighlight")
    b:SetHighlightFontObject("GameFontHighlight")
    b:SetDisabledFontObject("GameFontDisable")
    b:SetText(text)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", -1, 1)
    hl:SetColorTexture(1, 1, 1, 0.10)
    b:SetPushedTextOffset(1, -1)
    if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
    b:SetScript("OnEnter", function(self) Tip(self, self.why or self.tip) end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    Paint(b)
    return b
end

-- A link-style text button (Backups..., Back).
local function Link(parent, text)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(90, 20)
    b:SetNormalFontObject("GameFontHighlight")
    b:SetText(text)
    local fs = b.GetFontString and b:GetFontString()
    if fs then fs:SetTextColor(0.45, 0.70, 1) end
    return b
end

-- The one popup list, shared by every picker and menu. Items:
-- { text, value }; a pick hides it and calls onPick(value).
local function Menu()
    if W.menu then return W.menu end
    local mf = CreateFrame("Frame", "AltStableSyncMenu", UIParent, "BackdropTemplate")
    mf:SetFrameStrata("FULLSCREEN_DIALOG")
    mf:EnableMouse(true)
    if mf.SetBackdrop then
        mf:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        mf:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
        mf:SetBackdropBorderColor(0.55, 0.52, 0.45, 1)
    end
    mf.items = {}
    mf:Hide()
    mf:SetScript("OnShow", function() Panel.SyncEscape() end)
    mf:SetScript("OnHide", function() Panel.SyncEscape() end)
    tinsert(UISpecialFrames, "AltStableSyncMenu")
    W.menu = mf
    return mf
end

-- A list never runs off the screen (Codex on #60): at most MENU_ROWS rows,
-- fewer when the space below its owner is short, and the mouse wheel scrolls
-- the rest. Arrows say there is more above or below; it opens scrolled to
-- the current choice.
local MENU_ROWS, MENU_ROW = 12, 22

local function MenuRow(mf, i)
    local b = mf.items[i]
    if b then return b end
    b = CreateFrame("Button", nil, mf)
    b:SetHeight(MENU_ROW)
    b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * MENU_ROW)
    b:SetPoint("RIGHT", -18, 0)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    b.text = Text(b, "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 8, 0)
    b.text:SetPoint("RIGHT", -4, 0)
    b.text:SetWordWrap(false)
    b:SetScript("OnClick", function(self)
        mf:Hide()
        if mf.onPick then mf.onPick(self.value) end
    end)
    mf.items[i] = b
    return b
end

local function DrawMenu(mf)
    for i = 1, mf.rows do
        local it = mf.all[mf.offset + i]
        local b = MenuRow(mf, i)
        -- Every menu shows its items literally (#75): idempotent, so text
        -- the model already escaped is unchanged.
        b.text:SetText(it and ASS.Literal(it.text) or "")
        b.value = it and it.value
        if it then b:Show() else b:Hide() end
    end
    for i = mf.rows + 1, #mf.items do mf.items[i]:Hide() end
    if mf.offset > 0 then mf.up:Show() else mf.up:Hide() end
    if mf.offset + mf.rows < #mf.all then mf.down:Show() else mf.down:Hide() end
end

-- How many rows fit below `owner` on screen (all of them when it can't tell).
local function RowsBelow(owner)
    local bottom = owner.GetBottom and owner:GetBottom()
    if type(bottom) ~= "number" then return MENU_ROWS end
    local scale = (owner.GetEffectiveScale and owner:GetEffectiveScale() or 1)
        / ((UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1)
    return math.max(4, math.floor((bottom * scale - 16) / MENU_ROW))
end

local function OpenMenu(owner, items, onPick, current)
    local mf = Menu()
    if mf:IsShown() and mf.owner == owner then mf:Hide() return end
    if not mf.up then
        local function arrow(flip)
            local t = mf:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
            t:SetSize(16, 16)
            if flip then t:SetTexCoord(0, 1, 1, 0) end
            return t
        end
        mf.up, mf.down = arrow(true), arrow(false)
        mf.up:SetPoint("TOPRIGHT", -2, -4)
        mf.down:SetPoint("BOTTOMRIGHT", -2, 4)
        mf:EnableMouseWheel(true)
        mf:SetScript("OnMouseWheel", function(self, delta)
            local max = math.max(0, #self.all - self.rows)
            self.offset = math.max(0, math.min(max, self.offset - delta))
            DrawMenu(self)
        end)
    end
    mf.owner, mf.all, mf.onPick = owner, items, onPick
    mf.rows = math.min(#items, MENU_ROWS, RowsBelow(owner))
    mf.offset = 0
    for i, it in ipairs(items) do
        if current ~= nil and it.value == current and i > mf.rows then
            mf.offset = math.min(i - 1, #items - mf.rows)
        end
    end
    DrawMenu(mf)
    mf:SetSize(math.max(160, owner:GetWidth() or 160), 8 + mf.rows * MENU_ROW)
    mf:ClearAllPoints()
    mf:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    mf:Show()
end

local function CloseMenu() if W.menu then W.menu:Hide() end end

local function Special(name, on)
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == name then
            if on then return end
            table.remove(UISpecialFrames, i)
        end
    end
    if on then tinsert(UISpecialFrames, name) end
end

-- The panel is an Escape target only when nothing of ours is open above it.
-- Rejoining waits a frame, so the Escape that closed a preview doesn't reach
-- the panel through the list it is still walking.
-- Each by name: any of them may not exist yet (a list with a nil in it
-- would stop ipairs early).
local function Over()
    local function on(f) return f ~= nil and f:IsShown() end
    return on(_G.AltStableSyncPreview) or on(W.dialog) or on(W.menu) or on(W.share) or on(W.import)
end

function Panel.SyncEscape()
    if Over() then
        Special("AltStableSyncPanel", false)
    elseif C_Timer and C_Timer.After then
        C_Timer.After(0, function() Special("AltStableSyncPanel", not Over()) end)
    else
        Special("AltStableSyncPanel", true)
    end
end
if ASS.Preview then ASS.Preview.onVisibility = function() Panel.SyncEscape() end end

-- A picker: a field showing the current choice, left-aligned, with a
-- dropdown chevron; a click opens its list. p.label holds the value.
local function Picker(parent, width)
    local p = GButton(parent, "", width, "secondary")
    p.kind = "field"
    Paint(p)
    p.label = Text(p, "GameFontHighlight", width - 40, BODY)
    p.label:SetPoint("LEFT", 10, 0)
    p.label:SetWordWrap(false)
    local arrow = p:CreateTexture(nil, "OVERLAY")
    -- The client's own dropdown button art; an older arrow if the atlas is missing.
    if not (arrow.SetAtlas and pcall(arrow.SetAtlas, arrow, "common-dropdown-a-button")) then
        arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    end
    arrow:SetSize(22, 22)
    arrow:SetPoint("RIGHT", -3, 0)
    p:SetScript("OnClick", function(self) OpenMenu(self, self.items or {}, self.onPick, self.value) end)
    return p
end

------------------------------------------------------------
-- The name dialog: Save As (category + name) and Rename (name)
------------------------------------------------------------

local NAME_COPY = {
    ["name-empty"] = "Give it a name.",
    ["name-duplicate"] = "This class already has a loadout with that name in this category.",
}

local function Dialog()
    if W.dialog then return W.dialog end
    local d = CreateFrame("Frame", "AltStableSyncNameDialog", UIParent, "BackdropTemplate")
    d:SetSize(340, 196)
    d:SetPoint("CENTER", 0, 60)
    d:SetFrameStrata("DIALOG")
    d:EnableMouse(true)
    if d.SetBackdrop then
        d:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        d:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
        d:SetBackdropBorderColor(0.55, 0.52, 0.45, 1)
    end
    tinsert(UISpecialFrames, "AltStableSyncNameDialog")
    d.title = Text(d, "GameFontNormalLarge", 300)
    d.title:SetWordWrap(false)
    d.title:SetPoint("TOPLEFT", PAD, -16)
    d.intro = Text(d, "GameFontHighlightSmall", 300, MUTED)
    d.intro:SetPoint("TOPLEFT", PAD, -40)
    d.catLabel = Text(d, "GameFontNormal", 300)
    d.catLabel:SetPoint("TOPLEFT", PAD, -62)
    d.catLabel:SetText("Category")
    d.cat = Picker(d, 304)
    d.cat:SetPoint("TOPLEFT", PAD, -78)
    d.nameLabel = Text(d, "GameFontNormal", 300)
    d.name = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.name:SetSize(296, 22)
    d.name:SetAutoFocus(false)
    d.name:SetMaxLetters(60)
    d.nameLabel:SetText("Name")
    d.hint = Text(d, "GameFontRedSmall", 300)
    d.cancel = GButton(d, "Cancel", 100, "secondary")
    d.cancel:SetPoint("BOTTOMRIGHT", -PAD, 14)
    d.review = GButton(d, "Review...", 120, "primary")
    d.review:SetPoint("RIGHT", d.cancel, "LEFT", -8, 0)
    d.cancel:SetScript("OnClick", function() d:Hide() end)
    d:SetScript("OnShow", function() Panel.SyncEscape() end)
    d:SetScript("OnHide", function() CloseMenu(); Panel.SyncEscape() end)
    -- The check: an untouched or blank box just keeps Review off; the red
    -- text comes only for a typed name that won't work, or a Review attempt.
    function d.Check(showEmpty)
        local trimmed, err
        if ASS.disabled or not ASS.db then trimmed, err = nil, "unavailable"
        else
            trimmed, err = ASS.Catalog.ValidateName("loadout", PlayerClass(), d.category, d.name:GetText(), d.exceptId)
        end
        local show = not trimmed and (err ~= "name-empty" or showEmpty) and err ~= "unavailable"
        d.hint:SetText(show and (NAME_COPY[err] or tostring(err)) or "")
        Set(d.review, trimmed ~= nil and (not d.needsWrite or Panel.CanWrite()),
            not trimmed and (NAME_COPY[err] or "Not available now.") or Panel.WhyNot())
        return trimmed ~= nil
    end
    d.name:SetScript("OnTextChanged", function() d.Check(false) end)
    d.name:SetScript("OnEscapePressed", function() d:Hide() end)
    -- Enter reviews, never confirms: the preview still opens.
    d.name:SetScript("OnEnterPressed", function()
        if d.Check(true) then d.review:Click() end
    end)
    d.review:SetScript("OnClick", function()
        if not d.Check(true) then return end
        -- The values as they are at this click; the flow fixes them.
        local name, category, exceptId, mode = d.name:GetText(), d.category, d.exceptId, d.mode
        d:Hide()
        if mode == "saveas" then Cmd().SaveAsEntry(name, category)
        elseif exceptId then Cmd().RenameEntry(exceptId, name) end
    end)
    d:Hide()
    W.dialog = d
    return d
end

local function ShowNameDialog(mode, entry)
    local d = Dialog()
    CloseMenu()
    d.mode = mode
    local class = PlayerClass()
    if mode == "saveas" then
        d.needsWrite = true
        d.exceptId = nil
        d.category = Panel.DefaultCategory()
        d.title:SetText("Save As")
        d.intro:SetText("Creates a new loadout from this character. You'll review it before it's saved.")
        d.catLabel:Show(); d.cat:Show()
        d.nameLabel:SetPoint("TOPLEFT", PAD, -112)
        d.name:SetPoint("TOPLEFT", PAD + 6, -128)
        d.name:SetText("")
        local items = {}
        for _, c in ipairs(ASS.Categories.List(class) or {}) do items[#items + 1] = { text = c.label, value = c.key } end
        d.cat.items = items
        d.cat.label:SetText(ASS.Categories.Label(class, d.category))
        d.cat.value = d.category
        d.cat.onPick = function(key)
            d.category, d.cat.value = key, key
            d.cat.label:SetText(ASS.Categories.Label(class, key))
            d.Check(false)
        end
    else
        d.needsWrite = false
        d.exceptId = entry.id
        d.category = entry.category
        d.title:SetText("Rename " .. ASS.Literal(entry.name))
        d.intro:SetText("Only the saved list changes; nothing on any character changes.")
        d.catLabel:Hide(); d.cat:Hide()
        d.nameLabel:SetPoint("TOPLEFT", PAD, -62)
        d.name:SetPoint("TOPLEFT", PAD + 6, -78)
        -- The form the client gives typed text (#75): a typed name comes back
        -- unchanged, a crafted one neutralised.
        d.name:SetText(ASS.Literal(entry.name))
    end
    d.hint:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", -6, -4)
    d:Show()
    d.Check(false)
    d.name:SetFocus()
end

------------------------------------------------------------
-- Share and Import (#71): our own frames, never a StaticPopup
------------------------------------------------------------

-- A dialog frame in the name dialog's look, closed by Escape.
local function DialogFrame(name, width, height)
    local d = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    d:SetSize(width, height)
    d:SetPoint("CENTER", 0, 60)
    d:SetFrameStrata("DIALOG")
    d:EnableMouse(true)
    if d.SetBackdrop then
        d:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        d:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
        d:SetBackdropBorderColor(0.55, 0.52, 0.45, 1)
    end
    tinsert(UISpecialFrames, name)
    d.title = Text(d, "GameFontNormalLarge", width - 40)
    d.title:SetWordWrap(false)
    d.title:SetPoint("TOPLEFT", PAD, -16)
    d.intro = Text(d, "GameFontHighlightSmall", width - 40, MUTED)
    d.intro:SetPoint("TOPLEFT", PAD, -40)
    return d
end

-- A multi-line text box that scrolls to its cursor. Returns the holder and
-- the edit box.
local function TextBox(parent, width, height, onEscape)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    holder:SetSize(width, height)
    if holder.SetBackdrop then
        holder:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        holder:SetBackdropColor(0, 0, 0, 0.5)
        holder:SetBackdropBorderColor(1, 1, 1, 0.18)
    end
    local sc = CreateFrame("ScrollFrame", nil, holder)
    sc:SetPoint("TOPLEFT", 6, -6)
    sc:SetPoint("BOTTOMRIGHT", -6, 6)
    local eb = CreateFrame("EditBox", nil, sc)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetWidth(width - 12)
    eb:SetMaxLetters(ASS.Envelope.BOX_MAX)
    sc:SetScrollChild(eb)
    eb:SetScript("OnCursorChanged", function(_, _, y, _, h)
        local top, view = sc:GetVerticalScroll(), sc:GetHeight() or height
        y = -(y or 0)
        if y < top then sc:SetVerticalScroll(y)
        elseif y + (h or 0) > top + view then sc:SetVerticalScroll(y + (h or 0) - view) end
    end)
    eb:SetScript("OnEscapePressed", function() onEscape() end)
    sc:EnableMouseWheel(true)
    sc:SetScript("OnMouseWheel", function(self, delta)
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 30)))
    end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function() eb:SetFocus() end)
    return holder, eb
end

local function ShareDialog()
    if W.share then return W.share end
    local d = DialogFrame("AltStableSyncShareDialog", 420, 300)
    d.holder, d.box = TextBox(d, 384, 150, function() d:Hide() end)
    d.holder:SetPoint("TOPLEFT", PAD, -76)
    -- Read-only: an edit by the player is put back (SetText's own change
    -- isn't user input, so this never recurses).
    d.box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(d.text or ""); self:HighlightText() end
    end)
    d.box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    d.note = Text(d, "GameFontHighlightSmall", 384, MUTED)
    d.note:SetPoint("TOPLEFT", d.holder, "BOTTOMLEFT", 0, -8)
    d.note:SetText("It holds this loadout's bars, keys and macro text, and no account or character "
        .. "details. Macro text may name people.")
    d.close = GButton(d, "Close", 100, "secondary")
    d.close:SetPoint("BOTTOMRIGHT", -PAD, 14)
    d.close:SetScript("OnClick", function() d:Hide() end)
    d:SetScript("OnShow", function() Panel.SyncEscape() end)
    d:SetScript("OnHide", function() d.box:ClearFocus(); Panel.SyncEscape() end)
    d:Hide()
    W.share = d
    return d
end

-- Manage > Share...: the browsed loadout's string, selected for Ctrl+C. An
-- addon can't write the clipboard.
local function ShowShare(entry)
    local d = ShareDialog()
    CloseMenu()
    local text, err = ASS.Share.Encode(entry)
    d.title:SetText("Share " .. ASS.Share.Literal(entry.name))
    d.text = text
    if text then
        d.intro:SetText("Press Ctrl+C to copy, then paste it into Import on the other character.")
        d.holder:Show(); d.note:Show()
        d.box:SetText(text)
    else
        d.intro:SetText(ASS.Share.Copy(err))
        d.holder:Hide(); d.note:Hide()
        d.box:SetText("")
    end
    d:Show()
    if text then d.box:SetFocus(); d.box:HighlightText() end
end

local IMPORT_WAIT = 0.3

local function ImportDialog()
    if W.import then return W.import end
    local d = DialogFrame("AltStableSyncImportDialog", 420, 372)
    d.intro:SetText("Paste a loadout string (Ctrl+V). You'll review it before it's saved; nothing on this character changes.")
    d.holder, d.box = TextBox(d, 384, 110, function() d:Hide() end)
    d.holder:SetPoint("TOPLEFT", PAD, -76)
    d.status = Text(d, "GameFontHighlightSmall", 384, BODY)
    d.status:SetPoint("TOPLEFT", d.holder, "BOTTOMLEFT", 0, -6)
    d.catLabel = Text(d, "GameFontNormal", 384)
    d.catLabel:SetPoint("TOPLEFT", PAD, -222)
    d.catLabel:SetText("Category")
    d.cat = Picker(d, 384)
    d.cat:SetPoint("TOPLEFT", PAD, -238)
    d.nameLabel = Text(d, "GameFontNormal", 384)
    d.nameLabel:SetPoint("TOPLEFT", PAD, -272)
    d.nameLabel:SetText("New loadout name")
    d.name = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.name:SetSize(376, 22)
    d.name:SetPoint("TOPLEFT", PAD + 6, -288)
    d.name:SetAutoFocus(false)
    d.name:SetMaxLetters(60)
    d.hint = Text(d, "GameFontRedSmall", 384)
    d.hint:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", -6, -4)
    d.cancel = GButton(d, "Cancel", 100, "secondary")
    d.cancel:SetPoint("BOTTOMRIGHT", -PAD, 14)
    d.review = GButton(d, "Review...", 120, "primary")
    d.review:SetPoint("RIGHT", d.cancel, "LEFT", -8, 0)
    d.cancel:SetScript("OnClick", function() d:Hide() end)
    d.token = 0

    local function SetCategory(key)
        local class = PlayerClass()
        d.category, d.cat.value = key, key
        d.cat.label:SetText(ASS.Categories.Label(class, key))
    end
    -- Review needs a decoded, validated draft of exactly the text in the box
    -- and a name that works.
    function d.Check(showEmpty)
        local trimmed, err
        if ASS.disabled or not ASS.db then trimmed, err = nil, "unavailable"
        elseif not d.draft then trimmed, err = nil, "no-draft"
        else
            trimmed, err = ASS.Catalog.ValidateName("loadout", PlayerClass(), d.category, d.name:GetText())
        end
        local show = not trimmed and (err ~= "name-empty" or showEmpty) and NAME_COPY[err] ~= nil
        d.hint:SetText(show and NAME_COPY[err] or "")
        Set(d.review, trimmed ~= nil, not trimmed and (NAME_COPY[err] or "Paste a loadout string first.") or nil)
        return trimmed ~= nil
    end
    function d.Decode()
        local text = d.box:GetText() or ""
        d.draft = nil
        if not text:find("%S") then
            d.status:SetText("")
        else
            local x, err = ASS.Share.Decode(text)
            local class = PlayerClass()
            if not x then
                d.status:SetText("|cffff5555" .. ASS.Share.Copy(err) .. "|r")
            elseif x.class ~= class then
                local label = ASS.Share.ClassLabel(x.class)
                d.status:SetText(("|cffff5555This is a %s loadout: import it on a %s.|r"):format(
                    ASS.Share.Literal(label), ASS.Share.Literal(label)))
            else
                d.draft = x
                d.status:SetText(("A %s loadout: %s"):format(ASS.Share.ClassLabel(class), ASS.Share.Literal(x.name)))
                -- The string's category until the player picks one, and its
                -- name until the player types one: each on its own, so a
                -- replaced paste never keeps the last string's category.
                if not d.catPicked then
                    SetCategory(ASS.Categories.IsValid(class, x.category) and x.category or "general")
                end
                if not d.nameTyped then d.name:SetText(ASS.Literal(x.name)) end
            end
        end
        d.Check(false)
    end
    -- Every change drops the draft at once; only the last change's timer
    -- decodes (a paste arrives as one change, typing as many).
    d.box:SetScript("OnTextChanged", function()
        d.draft = nil
        d.token = d.token + 1
        local token = d.token
        d.status:SetText(d.box:GetText():find("%S") and "Checking..." or "")
        d.Check(false)
        if C_Timer and C_Timer.After then
            C_Timer.After(IMPORT_WAIT, function()
                if d.token == token and d:IsShown() then d.Decode() end
            end)
        else
            d.Decode()
        end
    end)
    d.name:SetScript("OnTextChanged", function(_, userInput)
        if userInput then d.nameTyped = true end
        d.Check(false)
    end)
    d.name:SetScript("OnEscapePressed", function() d:Hide() end)
    -- Enter in the name box reviews, never confirms; in the paste box it is
    -- a new line.
    d.name:SetScript("OnEnterPressed", function()
        if d.Check(true) then d.review:Click() end
    end)
    d.review:SetScript("OnClick", function()
        if not d.Check(true) then return end
        -- Frozen at this click; the confirm never reads the dialog again.
        local frozen = { class = PlayerClass(), category = d.category, name = d.name:GetText(),
                         modules = ASS.Catalog.Copy(d.draft.modules) }
        d:Hide()
        Cmd().ImportEntry(frozen, function(e)
            Panel.sel.category, Panel.sel.id, Panel.sel.noDefault = e.category, e.id, false
            Panel.Refresh()
        end)
    end)
    d:SetScript("OnShow", function() Panel.SyncEscape() end)
    -- A decode still pending when the dialog hides does nothing (the timer
    -- checks it is shown; reopening clears the box, a newer change).
    d:SetScript("OnHide", function()
        d.box:ClearFocus(); d.name:ClearFocus()
        CloseMenu()
        Panel.SyncEscape()
    end)
    d:Hide()
    W.import = d
    return d
end

local function ShowImport()
    local d = ImportDialog()
    CloseMenu()
    local class = PlayerClass()
    d.title:SetText("Import a loadout")
    local items = {}
    for _, c in ipairs(ASS.Categories.List(class) or {}) do items[#items + 1] = { text = c.label, value = c.key } end
    d.cat.items = items
    d.cat.onPick = function(key)
        d.catPicked = true
        d.category, d.cat.value = key, key
        d.cat.label:SetText(ASS.Categories.Label(class, key))
        d.Check(false)
    end
    d.catPicked = false
    d.category, d.cat.value = "general", "general"
    d.cat.label:SetText(ASS.Categories.Label(class, "general"))
    d.nameTyped = false
    d:Show()
    d.box:SetText("")
    d.name:SetText("")
    d.nameTyped = false
    d.draft = nil
    d.Check(false)
    d.box:SetFocus()
end

-- /altsync import, and the panel's Import... button.
function Panel.OpenImport() ShowImport() end

------------------------------------------------------------
-- The window
------------------------------------------------------------

-- Whether a write can start now, and why not: Loadout.Blocked's own answer
-- (combat, readiness, something on the cursor), so the buttons and the
-- flows agree.
function Panel.WhyNot()
    local ok, why = pcall(function() return ASS.Loadout.Blocked() end)
    if not ok then return "Not available now." end
    return why
end

function Panel.CanWrite() return Panel.WhyNot() == nil end

local function ShowView(view)
    Panel.view = view
    CloseMenu()
    Panel.Refresh()
end

local function SummaryRow(i)
    local r = W.rows[i]
    if r then return r end
    r = {}
    r.label = Text(W.box, "GameFontHighlight", 120, MUTED)
    r.value = Text(W.box, "GameFontHighlight", 210, BODY)
    r.sub = Text(W.box, "GameFontHighlightSmall", 210, MUTED)
    r.line = W.box:CreateTexture(nil, "ARTWORK")
    r.line:SetColorTexture(1, 1, 1, 0.07)
    r.line:SetHeight(1)
    W.rows[i] = r
    return r
end

-- Rows top to bottom, each as tall as its lines; a divider between rows,
-- clear of both. Returns the box height they need.
local ROW, ROW2, TOP, FOOT = 26, 40, 30, 30
local function LayRows(contents)
    local y = -TOP
    for i, row in ipairs(contents) do
        local r = SummaryRow(i)
        if i > 1 then
            r.line:ClearAllPoints()
            r.line:SetPoint("TOPLEFT", 10, y + 4)
            r.line:SetPoint("TOPRIGHT", -10, y + 4)
            r.line:Show()
        end
        r.label:ClearAllPoints(); r.label:SetPoint("TOPLEFT", 12, y - 4)
        r.value:ClearAllPoints(); r.value:SetPoint("TOPLEFT", 140, y - 4)
        r.sub:ClearAllPoints(); r.sub:SetPoint("TOPLEFT", 140, y - 20)
        r.label:SetText(row.label); r.value:SetText(row.value); r.sub:SetText(row.sub or "")
        r.label:Show(); r.value:Show(); r.sub:Show()
        y = y - (row.sub and ROW2 or ROW)
    end
    return -y + FOOT
end

local function BuildLoadouts(v)
    local w = WIDTH - 2 * PAD
    local catLabel = Text(v, "GameFontNormal", w)
    catLabel:SetPoint("TOPLEFT", 0, 0)
    catLabel:SetText("Category")
    W.cat = Picker(v, w)
    W.cat:SetPoint("TOPLEFT", 0, -16)
    W.cat.onPick = function(key)
        Panel.sel.category, Panel.sel.id, Panel.sel.noDefault = key, nil, false
        Panel.Refresh()
    end
    local entLabel = Text(v, "GameFontNormal", w)
    entLabel:SetPoint("TOPLEFT", 0, -50)
    entLabel:SetText("Saved loadout")
    W.entry = Picker(v, w)
    W.entry:SetPoint("TOPLEFT", 0, -66)
    W.entry.onPick = function(id)
        Panel.sel.id, Panel.sel.noDefault = id, false
        Panel.Refresh()
    end

    -- The selected entry's saved contents (its height follows its rows).
    local box = CreateFrame("Frame", nil, v, "BackdropTemplate")
    box:SetSize(w, 132)
    box:SetPoint("TOPLEFT", 0, -102)
    box:EnableMouse(true)
    box:SetScript("OnEnter", function(self) Tip(self, self.tip) end)
    box:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    if box.SetBackdrop then
        box:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        box:SetBackdropColor(0, 0, 0, 0.35)
        box:SetBackdropBorderColor(1, 1, 1, 0.12)
    end
    W.box, W.rows = box, {}
    W.boxTitle = Text(box, "GameFontNormalSmall", w - 24, MUTED)
    W.boxTitle:SetWordWrap(false)
    W.boxTitle:SetPoint("TOPLEFT", 12, -8)
    W.boxNote = Text(box, "GameFontHighlight", w - 24, BODY)
    W.boxNote:SetPoint("TOPLEFT", 12, -30)
    W.boxFoot = Text(box, "GameFontHighlightSmall", w - 24, MUTED)
    W.boxFoot:SetPoint("BOTTOMLEFT", 12, 8)

    W.load = GButton(v, "Load...", 160, "primary")
    W.load:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -10)
    W.load:SetScript("OnClick", function()
        local e = Cmd().Own(Panel.sel.id)
        if e then CloseMenu(); Cmd().LoadEntry(e) end
    end)
    W.manage = GButton(v, "Manage...", 104, "secondary")
    W.manage:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -10)
    W.manage:SetScript("OnClick", function(self)
        local e = Cmd().Own(Panel.sel.id)
        if not e then return end
        if e.conflict then
            local c = e.conflict
            local from = tostring(c.from or "your other account")
            OpenMenu(self, {
                { text = c.deletion and "Keep it..." or "Keep this account's version...", value = "mine" },
                { text = c.deletion and "Delete it here too..." or ("Use the version from " .. from .. "..."), value = "theirs" },
            }, function(choice) Cmd().ResolveCopy(e.id, choice) end)
        else
            OpenMenu(self, { { text = "Rename...", value = "rename" }, { text = "Share...", value = "share" },
                             { text = "Delete...", value = "delete" } },
                function(what)
                    local cur = Cmd().Own(e.id)
                    if not cur then return end
                    if what == "rename" then ShowNameDialog("rename", cur)
                    elseif what == "share" then ShowShare(cur)
                    else Cmd().DeleteEntry(cur.id) end
                end)
        end
    end)
    -- A loadout from a string (#71): a new entry, after a preview.

    W.importBtn = GButton(v, "Import...", 90, "secondary")
    W.importBtn:SetPoint("RIGHT", W.manage, "LEFT", -6, 0)
    W.importBtn:SetScript("OnClick", function() ShowImport() end)
    W.loadHint = Text(v, "GameFontHighlightSmall", w, MUTED)
    W.loadHint:SetPoint("TOPLEFT", W.load, "BOTTOMLEFT", 2, -6)

    local sep = v:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.30)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", W.load, "BOTTOMLEFT", 0, -30)
    sep:SetPoint("RIGHT", v, "RIGHT", 0, 0)

    -- Save this character: the save target, whatever is browsed.
    local head = Text(v, "GameFontNormal", w)
    head:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -12)
    head:SetText("SAVE THIS CHARACTER")
    W.target = Text(v, "GameFontHighlight", w, BODY)
    W.target:SetWordWrap(false)
    W.target:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)
    W.targetNote = Text(v, "GameFontHighlightSmall", w, MUTED)
    W.targetNote:SetPoint("TOPLEFT", W.target, "BOTTOMLEFT", 0, -3)
    W.saveStatus = Text(v, "GameFontHighlightSmall", w, BODY)
    W.saveStatus:SetPoint("TOPLEFT", W.targetNote, "BOTTOMLEFT", 0, -3)
    W.save = GButton(v, "Save...", 140, "secondary")
    W.save:SetPoint("TOPLEFT", W.saveStatus, "BOTTOMLEFT", 0, -10)
    W.save:SetScript("OnClick", function() CloseMenu(); Cmd().save("") end)
    W.saveAs = GButton(v, "Save As...", 140, "secondary")
    W.saveAs:SetPoint("LEFT", W.save, "RIGHT", 10, 0)
    W.saveAs:SetScript("OnClick", function() ShowNameDialog("saveas") end)
    local saveHint = Text(v, "GameFontHighlightSmall", w, MUTED)
    saveHint:SetPoint("TOPLEFT", W.save, "BOTTOMLEFT", 2, -8)
    saveHint:SetText("Review before saving. Other characters stay unchanged.")
end

local function BackupRow(i)
    local r = W.brows[i]
    if r then return r end
    r = CreateFrame("Button", nil, W.backupChild)
    r:SetSize(WIDTH - 2 * PAD - 4, 20)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.15)
    local over = r:CreateTexture(nil, "HIGHLIGHT")
    over:SetAllPoints()
    over:SetColorTexture(1, 1, 1, 0.07)
    r.text = Text(r, "GameFontHighlightSmall", WIDTH - 2 * PAD - 16, BODY)
    r.text:SetPoint("LEFT", 6, 0)
    r:SetScript("OnClick", function(self)
        Panel.sel.snap = self.snap
        Panel.Refresh()
    end)
    W.brows[i] = r
    return r
end

local function BuildBackups(v)
    local w = WIDTH - 2 * PAD
    local intro = Text(v, "GameFontHighlightSmall", w, MUTED)
    intro:SetPoint("TOPLEFT", 0, 0)
    intro:SetText("Taken before every load and restore, and by Back up now. Restore puts this character's bars and keys back as they were.")
    local sc = CreateFrame("ScrollFrame", nil, v)
    sc:SetSize(w, 260)
    sc:SetPoint("TOPLEFT", 0, -36)
    local child = CreateFrame("Frame", nil, sc)
    child:SetSize(w, 10)
    sc:SetScrollChild(child)
    sc:EnableMouseWheel(true)
    sc:SetScript("OnMouseWheel", function(self, delta)
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 60)))
    end)
    W.backupChild, W.brows = child, {}
    W.backupEmpty = Text(v, "GameFontHighlightSmall", w, MUTED)
    W.backupEmpty:SetPoint("TOPLEFT", 6, -42)
    W.restore = GButton(v, "Restore...", 140, "primary")
    W.restore:SetPoint("BOTTOMLEFT", 0, 10)
    W.backupNow = GButton(v, "Back up now", 140, "secondary")
    W.backupNow:SetPoint("LEFT", W.restore, "RIGHT", 10, 0)
    W.backupNow:SetScript("OnClick", function() CloseMenu(); Cmd().backup() end)
    W.restore:SetScript("OnClick", function()
        local slot = Panel.SlotOf(Panel.sel.snap)
        if not slot then
            Panel.message, Panel.messageAt = "That backup is no longer in the list.", GetTime()
            Panel.sel.snap = nil
            Panel.Refresh()
            return
        end
        Cmd().restore(slot)
    end)
end

local function BuildUI(v)
    local t = Text(v, "GameFontHighlight", WIDTH - 2 * PAD, BODY)
    t:SetPoint("TOPLEFT", 0, -4)
    t:SetText("Saved UI setups (Edit Mode layout and settings) aren't available yet.")
end

local function Build()
    local f = CreateFrame("Frame", "AltStableSyncPanel", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, ABOVE_BOX + 152 + BELOW_BOX + FOOTER)
    -- Held by its top edge: a taller contents box grows the window downward.
    f:SetPoint("TOP", UIParent, "TOP", 0, -90)
    -- HIGH: above unit frames and action bars (MEDIUM, often at high frame
    -- levels); our previews and dialogs (DIALOG) and lists still open above it.
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ASS.Preview.Glass(f)
    -- Smoked glass under the text: the rim stays glass, the reading area
    -- doesn't show the world through it.
    local smoke = f:CreateTexture(nil, "BACKGROUND", nil, 7)
    smoke:SetPoint("TOPLEFT", 6, -6)
    smoke:SetPoint("BOTTOMRIGHT", -6, 6)
    smoke:SetColorTexture(0.02, 0.02, 0.035, 0.84)
    Panel.SyncEscape()

    W.title = Text(f, "GameFontNormalHuge", 300, GOLD)
    W.title:SetPoint("TOPLEFT", PAD, -16)
    W.title:SetText("AltStableSync")
    W.class = Text(f, "GameFontHighlight", 300, BODY)
    W.class:SetPoint("TOPLEFT", PAD + 2, -44)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- Navigation: two tabs, and Backups as a quieter link.
    W.tabs = {}
    local x = PAD
    for _, t in ipairs({ { "loadouts", "Loadouts" }, { "ui", "UI setup" } }) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(100, 24)
        b:SetPoint("TOPLEFT", x, -66)
        b:SetNormalFontObject("GameFontHighlight")
        b:SetText(t[2])
        b.line = b:CreateTexture(nil, "ARTWORK")
        b.line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        b.line:SetHeight(2)
        b.line:SetPoint("BOTTOMLEFT", 6, -2)
        b.line:SetPoint("BOTTOMRIGHT", -6, -2)
        b:SetScript("OnClick", function() ShowView(t[1]) end)
        W.tabs[t[1]] = b
        x = x + 104
    end
    W.backupsLink = Link(f, "Backups...")
    W.backupsLink:SetPoint("TOPRIGHT", -PAD, -68)
    W.backupsLink:SetScript("OnClick", function() ShowView(Panel.view == "backups" and "loadouts" or "backups") end)
    local navLine = f:CreateTexture(nil, "ARTWORK")
    navLine:SetColorTexture(1, 1, 1, 0.10)
    navLine:SetHeight(1)
    navLine:SetPoint("TOPLEFT", PAD, -93)
    navLine:SetPoint("TOPRIGHT", -PAD, -93)

    W.views = {}
    for _, key in ipairs({ "loadouts", "backups", "ui" }) do
        local v = CreateFrame("Frame", nil, f)
        v:SetPoint("TOPLEFT", PAD, -106)
        v:SetPoint("BOTTOMRIGHT", -PAD, FOOTER)
        W.views[key] = v
    end
    BuildLoadouts(W.views.loadouts)
    BuildBackups(W.views.backups)
    BuildUI(W.views.ui)

    W.blocked = Text(f, "GameFontHighlight", WIDTH - 2 * PAD, BODY)
    W.blocked:SetPoint("TOPLEFT", PAD, -110)

    -- Footer: a small status, and the interrupted-load banner when there is one.
    -- A stronger backing under the footer: what's behind the window (unit
    -- frame numbers) never shows through the status.
    local footBack = f:CreateTexture(nil, "BACKGROUND", nil, 7)
    footBack:SetPoint("BOTTOMLEFT", 6, 6)
    footBack:SetPoint("BOTTOMRIGHT", -6, 6)
    footBack:SetHeight(FOOTER - 8)
    footBack:SetColorTexture(0.01, 0.01, 0.02, 0.88)
    local foot = f:CreateTexture(nil, "ARTWORK")
    foot:SetColorTexture(1, 1, 1, 0.10)
    foot:SetHeight(1)
    foot:SetPoint("BOTTOMLEFT", PAD, 44)
    foot:SetPoint("BOTTOMRIGHT", -PAD, 44)
    W.dot = f:CreateTexture(nil, "OVERLAY")
    W.dot:SetSize(8, 8)
    W.dot:SetPoint("BOTTOMLEFT", PAD + 2, 20)
    W.status = Text(f, "GameFontHighlightSmall", WIDTH - 2 * PAD - 120, MUTED)
    W.status:SetPoint("BOTTOMLEFT", PAD + 16, 18)
    W.undo = GButton(f, "Undo it...", 100, "secondary")
    W.undo:SetPoint("BOTTOMRIGHT", -PAD, 12)
    W.undo:SetScript("OnClick", function() CloseMenu(); Cmd().restore("op") end)

    -- The read-only tick: only while shown (a hidden frame gets no OnUpdate).
    local acc, saveAcc = 0, 0
    f:SetScript("OnUpdate", function(_, elapsed)
        acc, saveAcc = acc + elapsed, saveAcc + elapsed
        if Panel.dirty or acc >= REFRESH then acc, Panel.dirty = 0, false; Panel.Refresh() end
        if Panel.saveDirty or saveAcc >= SAVE_REFRESH then saveAcc, Panel.saveDirty = 0, false; Panel.RefreshSave() end
    end)
    -- Events only while shown: they mark the save status (and the model) dirty.
    f:SetScript("OnEvent", function() Panel.dirty, Panel.saveDirty = true, true end)
    f:SetScript("OnShow", function(self)
        for _, e in ipairs(SAVE_EVENTS) do pcall(self.RegisterEvent, self, e) end
    end)
    f:SetScript("OnHide", function(self)
        CloseMenu()
        for _, e in ipairs(SAVE_EVENTS) do pcall(self.UnregisterEvent, self, e) end
    end)
    -- A new frame starts shown, and Show() on a shown frame fires no OnShow:
    -- start hidden, so the first Show registers the events.
    f:Hide()
    frame = f
    return f
end

-- Redraw from a fresh model. Updates the panel's own widgets only; an open
-- preview or dialog is never touched.
function Panel.Refresh()
    if not (frame and frame:IsShown()) then return end
    local m = Panel.Model(Panel.sel)
    W.class:SetText(m.class and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[m.class] or m.class) or "")
    if m.blocked then
        W.blocked:SetText(m.blocked)
        W.blocked:Show()
        for _, v in pairs(W.views) do v:Hide() end
        for _, b in pairs(W.tabs) do b:Disable() end
        W.backupsLink:Hide(); W.undo:Hide(); W.dot:Hide()
        W.status:SetText("")
        return
    end
    W.blocked:Hide()
    for key, v in pairs(W.views) do if key == Panel.view then v:Show() else v:Hide() end end
    for key, b in pairs(W.tabs) do
        b:Enable()
        local fs = b.GetFontString and b:GetFontString()
        if key == Panel.view then
            b.line:Show()
            if fs then fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) end
        else
            b.line:Hide()
            if fs then fs:SetTextColor(BODY[1], BODY[2], BODY[3]) end
        end
    end
    W.backupsLink:Show()
    W.backupsLink:SetText(Panel.view == "backups" and "< Loadouts" or "Backups...")
    local whyNot = Panel.WhyNot()
    local canWrite = whyNot == nil

    -- What is browsed: kept for the session.
    if m.selectionGone then Panel.sel.id, Panel.sel.noDefault = nil, true end
    Panel.sel.category = m.category
    if m.selectedId then Panel.sel.id = m.selectedId end

    local catItems = {}
    for _, c in ipairs(m.categories) do
        catItems[#catItems + 1] = { text = c.label .. (c.count > 0 and ("  (" .. c.count .. ")") or ""), value = c.key }
    end
    W.cat.items, W.cat.value = catItems, m.category
    W.cat.label:SetText(m.categoryLabel)
    local entItems = {}
    for _, e in ipairs(m.entries) do entItems[#entItems + 1] = { text = e.text, value = e.id } end
    W.entry.items, W.entry.value = entItems, m.selectedId
    Set(W.entry, #entItems > 0, "No loadouts in this category.")
    local s = m.selected
    W.entry.label:SetText(s and s.name or (#entItems > 0 and "Choose a loadout" or "None"))
    W.entry.label:SetTextColor(BODY[1], BODY[2], BODY[3], #entItems > 0 and 1 or 0.5)

    for _, r in ipairs(W.rows) do r.label:Hide(); r.value:Hide(); r.sub:Hide(); r.line:Hide() end
    W.boxNote:SetText("")
    W.boxFoot:SetText("")
    W.box.tip = nil
    W.box:SetHeight(96)
    local boxHeight = 96
    if s then
        W.boxTitle:SetText("SAVED CONTENTS - " .. s.name:upper())
        if s.contents then
            boxHeight = LayRows(s.contents)
            W.box:SetHeight(boxHeight)
        else
            W.boxNote:SetText("Nothing to load: it stands for a deletion on " .. tostring(s.from) .. ".")
        end
        -- Short; the full time on hover. The markers live in the picker's list.
        W.boxFoot:SetText(s.saved)
        W.box.tip = s.savedFull
    else
        W.boxTitle:SetText("SAVED CONTENTS")
        if m.selectionGone or Panel.sel.noDefault then
            W.boxNote:SetText("That loadout was removed (perhaps from your other account). Choose another.")
        elseif m.noLoadouts then
            W.boxNote:SetText("No saved loadouts for this class yet. Save this character with Save As.")
        elseif m.emptyCategory then
            W.boxNote:SetText(("No loadouts in %s yet. Choose another category, or use Save As."):format(m.categoryLabel))
        else
            W.boxNote:SetText("Choose a loadout to see what it holds.")
        end
    end

    local copy = s and s.conflictCopy
    if s and not copy then
        W.load:Show()
        Set(W.load, canWrite, whyNot)
        W.loadHint:SetText("Review changes before loading.")
    else
        W.load:Hide()
        W.loadHint:SetText(copy and ("A conflict with " .. tostring(s.from) .. ": settle it with Manage.") or "")
    end
    if s then W.manage:Show(); Set(W.manage, true) else W.manage:Hide() end
    -- Without a browsed loadout, Import takes Manage's place.
    W.importBtn:ClearAllPoints()
    if s then W.importBtn:SetPoint("RIGHT", W.manage, "LEFT", -6, 0)
    else W.importBtn:SetPoint("TOPRIGHT", W.box, "BOTTOMRIGHT", 0, -10) end
    W.manage:SetText(copy and "Resolve..." or "Manage...")

    -- The window fits its contents, so the footer keeps its own band.
    frame:SetHeight(ABOVE_BOX + (Panel.view == "loadouts" and boxHeight or 152) + BELOW_BOX + FOOTER)

    -- Save this character.
    local t = m.target
    if not t then
        W.target:SetText("|cffffd100Save target:|r none yet")
        W.targetNote:SetText("Load a loadout to make it the save target, or use Save As.")
    elseif t.deleted then
        W.target:SetText("|cffffd100Save target:|r " .. tostring(t.name or "?") .. " (removed)")
        W.targetNote:SetText("It was deleted, so Save can't update it. Use Save As to keep this character's setup.")
    else
        W.target:SetText(("|cffffd100Save target:|r %s - %s%s"):format(t.name, tostring(t.category),
            t.older and " (changed since you loaded it)" or ""))
        W.targetNote:SetText(m.targetDiffers and "Browsing another loadout doesn't change this target." or "")
    end
    Set(W.saveAs, canWrite, whyNot)

    -- Backups.
    for i, b in ipairs(m.backups) do
        local r = BackupRow(i)
        r.snap = b.snap
        r.text:SetText(b.text)
        if b.selected then r.hl:Show() else r.hl:Hide() end
        r:Show()
    end
    for i = #m.backups + 1, #W.brows do W.brows[i]:Hide(); W.brows[i].snap = nil end
    W.backupChild:SetHeight(math.max(10, #m.backups * 20))
    W.backupEmpty:SetText(#m.backups == 0 and "No backups yet: one is taken before every load." or "")
    if m.backupGone then Panel.sel.snap = nil end
    Set(W.restore, canWrite and m.backupSelected, not m.backupSelected and "Select a backup first." or whyNot)
    Set(W.backupNow, canWrite, whyNot)

    -- Footer: a recent command message, else the state.
    local text, dot
    if Panel.message and Panel.messageAt and GetTime() - Panel.messageAt < MESSAGE_SECONDS then
        text = Panel.message
    elseif m.pinned then
        text, dot = ("A load of %s was interrupted."):format(m.pinned), { 1, 0.55, 0.1 }
    elseif not m.ready then
        text = "Waiting for character data."
    elseif m.combat then
        text = "In combat: loading, saving and restoring wait until it ends."
    elseif m.link then
        text, dot = m.link, m.online and { 0.2, 0.85, 0.3 } or { 0.5, 0.5, 0.5 }
    end
    W.status:SetText(text or "")
    if dot then W.dot:SetColorTexture(dot[1], dot[2], dot[3], 1); W.dot:Show() else W.dot:Hide() end
    if m.pinned then W.undo:Show(); Set(W.undo, canWrite, whyNot) else W.undo:Hide() end
end

-- The save target's status (a fresh PlanSave, once a second while shown).
function Panel.RefreshSave()
    if not (frame and frame:IsShown()) then return end
    local st = Panel.SaveStatus()
    W.saveStatus:SetText(st.text or "")
    -- "No unsaved changes" comes from PlanSave's own comparison: Save is off
    -- then, and says so. Save As stays available.
    Set(W.save, st.ok and Panel.CanWrite(), not st.ok and st.text or Panel.WhyNot())
end

function Panel.Show()
    if not frame then Build() end
    -- Each opening starts on the save target (docs/DESIGN.md), not on what
    -- was browsed last time.
    Panel.view = "loadouts"
    Panel.sel = { category = nil, id = nil, snap = nil, noDefault = false }
    frame:Show()
    ShowView(Panel.view)
    Panel.RefreshSave()
end

-- Open the window on a view ("loadouts", "backups" or "ui"), building and
-- showing it first if needed (#62: the minimap button's right-click opens
-- Backups). Panel.Show still starts on Loadouts and the save target.
function Panel.Open(view)
    if not (frame and frame:IsShown()) then Panel.Show() end
    if view and view ~= Panel.view then ShowView(view) end
end

function Panel.Hide() if frame then frame:Hide() end end

function Panel.Toggle()
    if frame and frame:IsShown() then frame:Hide() else Panel.Show() end
end

-- For the tests: the widgets.
Panel._W = W
function Panel._Frame() return frame end
function Panel._Dialog() return Dialog() end
function Panel._Share() return ShareDialog() end
function Panel._Import() return ImportDialog() end
Panel._ShowShare = function(e) ShowShare(e) end
