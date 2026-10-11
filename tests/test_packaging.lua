------------------------------------------------------------
-- test_packaging.lua - the TOC and .pkgmeta inputs
--
-- Nothing packages this addon yet, but the TOC is what the client loads: a
-- listed file that doesn't exist, or a literal version committed over the
-- packager keyword (it has happened twice on sibling projects), is caught here.
------------------------------------------------------------

dofile("tests/harness.lua")

local function read(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local s = h:read("*a"); h:close(); return s
end

local toc = read("AltStableSync.toc")
check("toc exists", toc ~= nil)
toc = toc or ""

check("interface 16001", toc:find("## Interface: 16001", 1, true) ~= nil)
check("version is the packager keyword", toc:find("## Version: @project-version@", 1, true) ~= nil)
check("account SVs", toc:find("## SavedVariables: AltStableSyncDB%s*[\r\n]") ~= nil)
-- LibAccountSync's store must never be declared here: the client would write the
-- household key into AltStableSync.lua, the file the beta->live transfer copies.
-- It belongs to the separate AltStableSyncLink addon (#18, docs/DESIGN.md).
check("LAS store not declared by the main addon", not toc:find("AltStableSyncLAS", 1, true))
check("character SV", toc:find("## SavedVariablesPerCharacter: AltStableSyncChar", 1, true) ~= nil)
check("AltStable is optional, not required", toc:find("## OptionalDeps: AltStable", 1, true) ~= nil
    and not toc:find("## Dependencies:", 1, true))

local files = {}
for line in (toc .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line ~= "" and not line:find("^#") then files[#files + 1] = line end
end

-- The runtime entries the addon cannot load without, in this order. The
-- glass XML comes first (it brings its own LibStub); modules follow Core.lua
-- as they land, so this is a required subsequence, not the whole list.
local REQUIRED = {
    "Libs\\LibGlass-1.0\\LibGlass-1.0.xml",
    "Libs\\LibStub\\LibStub.lua",
    "Core.lua",
    "Categories.lua",
    "Catalog.lua",
    "Envelope.lua",
    "Game.lua",
    "Pet.lua",
    "Backups.lua",
    "Ready.lua",
    "Loadout.lua",
    "Preview.lua",
    "Commands.lua",
}
do
    local at = 0
    for _, want in ipairs(REQUIRED) do
        local found
        for i = at + 1, #files do
            if files[i] == want then found = i; break end
        end
        check("toc lists " .. want .. " in order", found ~= nil)
        at = found or at
    end
end

-- Every listed file exists, except the externals the packager or the deploy
-- script fills in - and those only at their exact expected path, so a
-- misspelling can't hide behind the exemption.
local EXTERNAL = { ["Libs\\LibGlass-1.0\\LibGlass-1.0.xml"] = true }
for _, line in ipairs(files) do
    if not EXTERNAL[line] then
        local path = line:gsub("\\", "/")
        check("listed file exists: " .. path, read(path) ~= nil)
    end
end

-- .pkgmeta: the external is pinned to a tag, never latest, no inline comment.
local pkg = read(".pkgmeta") or ""
check("LibGlass pinned to a tag", pkg:find("Libs/LibGlass%-1%.0:%s*\r?\n%s+url: https://github.com/Spotnick2/LibGlass%s*\r?\n%s+tag: r%d+%s*\r?\n") ~= nil)
check("no tag: latest", not pkg:find("tag:%s*latest"))
for _, dir in ipairs({ "docs", "tests", "Tools", ".claude", ".github" }) do
    check(".pkgmeta ignores " .. dir, pkg:find("\n  %- " .. dir:gsub("%.", "%%.") .. "\r?\n") ~= nil)
end

-- Never a StaticPopup (it taints Blizzard's dialog pool; measured 70205): no
-- shipped file may call or touch one.
for _, line in ipairs(files) do
    local path = line:gsub("\\", "/")
    if path:match("%.lua$") then
        local src = read(path)
        if src then
            local code = src:gsub("%-%-[^\n]*", "")      -- comments may say "never a StaticPopup"
            check(path .. " never uses StaticPopup", not code:find("StaticPopup", 1, true))
        end
    end
end

------------------------------------------------------------
-- The Link addon (#18): Plugins/Link, shipped as top-level AltStableSyncLink.
------------------------------------------------------------
local LINK_DIR = "Plugins/Link/"
local LAS_XML = "Libs\\LibAccountSync-1.0\\LibAccountSync-1.0.xml"
local ltoc = read(LINK_DIR .. "AltStableSyncLink.toc")
check("link toc exists", ltoc ~= nil)
ltoc = ltoc or ""
check("link: interface 16001", ltoc:find("## Interface: 16001", 1, true) ~= nil)
check("link: version is the packager keyword", ltoc:find("## Version: @project-version@", 1, true) ~= nil)
check("link: depends on AltStableSync", ltoc:find("## Dependencies: AltStableSync%s*[\r\n]") ~= nil)
check("link: owns the LAS store", ltoc:find("## SavedVariables: AltStableSyncLAS%s*[\r\n]") ~= nil)
check("link: not LoadOnDemand", not ltoc:find("LoadOnDemand", 1, true))
check("link: no per-character store", not ltoc:find("SavedVariablesPerCharacter", 1, true))

local lfiles = {}
for line in (ltoc .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line ~= "" and not line:find("^#") then lfiles[#lfiles + 1] = line end
end
eq("link: loads the library, then Sync, then Link", table.concat(lfiles, ","),
   LAS_XML .. ",Sync.lua,Link.lua")
for _, line in ipairs(lfiles) do
    if line ~= LAS_XML then
        local path = LINK_DIR .. line:gsub("\\", "/")
        local src = read(path)
        check("link file exists: " .. path, src ~= nil)
        local code = (src or ""):gsub("%-%-[^\n]*", "")
        check(path .. " never uses StaticPopup", not code:find("StaticPopup", 1, true))
    end
end

-- The household key lives in exactly one file: the store is declared once.
local declared = 0
for _, t in ipairs({ toc, ltoc }) do
    if t:find("AltStableSyncLAS", 1, true) then declared = declared + 1 end
end
eq("LAS store declared in exactly one TOC", declared, 1)

-- .pkgmeta: the external key is a path from the project root and lands where
-- the Link TOC loads it once the folder is moved; move-folders names the
-- package. (A key prefixed with the package name would nest it elsewhere.)
local lasKey = LINK_DIR .. LAS_XML:gsub("\\", "/"):gsub("/LibAccountSync%-1%.0%.xml$", "")
check("LibAccountSync external at the Link addon's Libs, pinned to r5",
      pkg:find("\n  " .. lasKey:gsub("%p", "%%%0") .. ":%s*\r?\n%s+url: https://github.com/Spotnick2/LibAccountSync%s*\r?\n%s+tag: r5%s*\r?\n") ~= nil)
check("move-folders ships the Link addon top-level",
      pkg:find("\nmove%-folders:%s*\r?\n  AltStableSync/Plugins/Link: AltStableSyncLink%s*\r?\n") ~= nil)
check("no external under the package name", not pkg:find("\n  AltStableSync/[^\n]*Libs", 1))
for _, sub in ipairs({ "tests", "docs", "Tools", "CLAUDE.md", "README.md" }) do
    check(".pkgmeta ignores the library's " .. sub,
          pkg:find("\n  %- " .. (lasKey .. "/" .. sub):gsub("%p", "%%%0") .. "\r?\n") ~= nil)
end

-- Chat treats "|" as an escape: "<id|name>" printed as "<id", a line break,
-- "ame>" in game. A string literal may use "|" only for a colour code ("|c",
-- "|r"), a literal pipe ("||") or a " | " separator.
for _, path in ipairs({ "Core.lua", "Catalog.lua", "Commands.lua", "Envelope.lua",
                        "Plugins/Link/Link.lua", "Plugins/Link/Sync.lua" }) do
    local src = read(path) or ""
    local bad
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        local code = line:gsub("%-%-.*$", "")
        for lit in code:gmatch('"([^"]*)"') do
            local s = lit:gsub("||", "")
            if s:find("|[^cr ]") then bad = bad or lit end
        end
    end
    check(path .. ": no chat escape by accident (" .. tostring(bad) .. ")", bad == nil)
end

finish("test_packaging")
