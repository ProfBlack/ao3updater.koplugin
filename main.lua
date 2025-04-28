-- main.lua
-- AO3Updater: KOReader plugin – updates local AO3 EPUBs when the on‑site
-- version (date, word‑count or completed‑chapters) has changed.

--------------------------------------------------------------------------
-- requires
--------------------------------------------------------------------------
local InfoMessage     = require("ui/widget/infomessage")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("gettext")

local socket          = require("socket")          -- for tiny sleeps on SSL wants
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local PathChooser     = require("ui/widget/pathchooser")

--------------------------------------------------------------------------
-- class skeleton
--------------------------------------------------------------------------
local AO3Updater = WidgetContainer:extend{ name = "ao3updater", is_doc_only = false }

--------------------------------------------------------------------------
-- helpers (new)
--------------------------------------------------------------------------
local function parse_int(s)
    -- strip thousands separators and turn into number
    if not s then return nil end
    return tonumber((s:gsub(",", "")))
end

local function parse_chapters(field)
    -- field looks like "7/45", "12/?" or just "7"
    local done = field and field:match("^%s*([%d,]+)")
    return parse_int(done)
end

--------------------------------------------------------------------------
-- ctor / menu plumbing (unchanged)
--------------------------------------------------------------------------
function AO3Updater:init()
    local src        = debug.getinfo(1, "S").source or ""
    local plugin_dir = src:match("@(.+)/[^/]+$") or "."
    self.plugin_dir  = plugin_dir
    self.log_file    = plugin_dir .. "/ao3updater.log"

    self.settings_file = DataStorage:getSettingsDir() .. "/ao3updater.lua"
    self.settings      = LuaSettings:open(self.settings_file)
    self.default_dir   = self.settings:readSetting("default_dir")

    if self.ui.menu        then self.ui.menu:registerToMainMenu(self)        end
    if self.ui.librarymenu then self.ui.librarymenu:registerToMainMenu(self) end
end

function AO3Updater:log(msg)
    local f = io.open(self.log_file, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
        f:close()
    end
end

function AO3Updater:addToMainMenu(menu_items)
    menu_items.ao3_updater = {
        text         = _("AO3 Updater"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return {
                {
                    text = _("Update AO3 EPUBs"),
                    callback = function()
                        local ok, updated = xpcall(function() return self:run_update() end,
                            function(e)
                                local trace = debug.traceback(e, 2)
                                self:log("ERROR: " .. trace)
                                return false
                            end)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = _("Update failed, see log: ") .. self.log_file })
                        else
                            if updated and #updated > 0 then
                                UIManager:show(InfoMessage:new{ text = _("Update complete. Updated: ") .. table.concat(updated, ", ") })
                            else
                                UIManager:show(InfoMessage:new{ text = _("Update complete. No EPUBs were updated.") })
                            end
                        end
                    end,
                },
                {
                    text      = _("Set default directory"),
                    help_text = _("Choose a folder to scan for .epub files"),
                    callback  = function()
                        local chooser = PathChooser:new{
                            select_directory = true,
                            path             = self.default_dir or self.plugin_dir,
                            onConfirm        = function(dir)
                                self.default_dir = dir
                                self.settings:saveSetting("default_dir", dir)
                                self.settings:flush()
                                UIManager:show(InfoMessage:new{ text = _("Default directory set to: ") .. dir })
                            end,
                        }
                        UIManager:show(chooser)
                    end,
                },
            }
        end,
    }
end

--------------------------------------------------------------------------
-- scanning helpers (unchanged apart from minor tidy)
--------------------------------------------------------------------------
local function list_xhtml(epub)
    local files, p = {}, io.popen('unzip -qql "'..epub..'"')
    if p then
        for line in p:lines() do
            local fn = line:match("%s+%d+%s+%d+%-%d%d%-%d%d%s+[%d:]+%s+(.+)")
            if fn and fn:lower():match("%.xhtml$") then files[#files+1] = fn end
        end
        p:close()
    end
    return files
end

local function get_content(epub, entry)
    local p = io.popen('unzip -p "'..epub..'" "'..entry..'"')
    local c = p and p:read("*a") or ""
    if p then p:close() end
    return c
end

--------------------------------------------------------------------------
-- read meta from local EPUB (now returns words & chapters too)
--------------------------------------------------------------------------
function AO3Updater:get_epub_date_and_url(epub)
    local date_local, ao3_url, words_local, chapters_local

    for _, fn in ipairs(list_xhtml(epub)) do
        local raw     = get_content(epub, fn)
        local content = raw:gsub("%s+", " ")

        date_local = date_local
            or content:match("Updated:%s*([0-9][0-9][0-9][0-9]%-%d%d%-%d%d)")
            or content:match("Completed:%s*([0-9][0-9][0-9][0-9]%-%d%d%-%d%d)")

        ao3_url = ao3_url or content:match("(https?://archiveofourown.org/works/%d+)")

        words_local    = words_local    or parse_int(content:match("Words:%s*([%d,]+)"))
        chapters_local = chapters_local or parse_chapters(content:match("Chapters:%s*([%d,/%?]+)"))

        if date_local and ao3_url and words_local and chapters_local then break end
    end

    if ao3_url then ao3_url = ao3_url:gsub("^http://", "https://") end

    self:log(string.format("Local date=%s words=%s ch=%s URL=%s",
        tostring(date_local), tostring(words_local), tostring(chapters_local), tostring(ao3_url)))

    return date_local, ao3_url, words_local, chapters_local
end

--------------------------------------------------------------------------
-- fetch remote page, parse meta & EPUB link (now always asks for full view)
--------------------------------------------------------------------------
function AO3Updater:get_remote_info(ao3_url, https, ltn12)
    -- always request the full‑work page and pre‑accept the adult warning
    local req_url = ao3_url
    if req_url:find("?") then
        req_url = req_url .. "&view_adult=true&view_full_work=true"
    else
        req_url = req_url .. "?view_adult=true&view_full_work=true"
    end

    local max_retries, retries = 69, 0
    local ok, code, headers, status, resp

    repeat
        resp = {}
        ok, code, headers, status = https.request{
            url      = req_url,
            sink     = ltn12.sink.table(resp),
            protocol = "tlsv1_2",
            options  = "all",
            verify   = "none",
            headers  = { ["User-Agent"]='Mozilla/5.0', ["Accept"]='text/html', ["Connection"]='close' },
        }

        if not ok and (code == "wantread" or code == "wantwrite") then
            retries = retries + 1
            if retries >= max_retries then
                self:log("ERROR: SSL retries exceeded for " .. ao3_url)
                return nil, nil
            end
            socket.sleep(0.1)
        else
            break
        end
    until false

    local body = table.concat(resp)
    self:log(string.format("Fetched %d bytes, code=%s", #body, tostring(code)))
    if code ~= 200 or body == "" then
        self:log("--- DEBUG: non‑200 response body start ---")
        self:log(body:sub(1,512))
        self:log("--- DEBUG: non‑200 response body end ---")
        return nil, nil
    end

    -- meta fields
    local remote_date = body:match("<dt[^>]->%s*Updated:%s*</dt>%s*<dd[^>]->%s*(%d%d%d%d%-%d%d%-%d%d)%s*</dd>")
                     or body:match("<dt[^>]->%s*Completed:%s*</dt>%s*<dd[^>]->%s*(%d%d%d%d%-%d%d%-%d%d)%s*</dd>")
    local remote_words    = parse_int(body:match("<dt[^>]->%s*Words:%s*</dt>%s*<dd[^>]->%s*([%d,]+)%s*</dd>"))
    local remote_chapters = parse_chapters(body:match("<dt[^>]->%s*Chapters:%s*</dt>%s*<dd[^>]->%s*([%d,/%?]+)%s*</dd>"))

    -- EPUB link
    local raw_dl = body:match('href="([^"]+%.epub[^"]*)"')
    local download_url = raw_dl and (raw_dl:match("^https?://") and raw_dl or "https://archiveofourown.org" .. raw_dl)

    self:log(string.format("Remote date=%s words=%s ch=%s dl=%s",
        tostring(remote_date), tostring(remote_words), tostring(remote_chapters), tostring(download_url)))

    return remote_date, download_url, remote_words, remote_chapters
end

--------------------------------------------------------------------------
-- decide & download
--------------------------------------------------------------------------
function AO3Updater:process_epub(epub, https, ltn12)
    local local_date, ao3_url, local_words, local_chapters = self:get_epub_date_and_url(epub)
    if not (local_date and ao3_url) then return end  -- malformed local file

    local remote_date, download_url, remote_words, remote_chapters = self:get_remote_info(ao3_url, https, ltn12)
    if not remote_date or not download_url then return end

    ------------------------------------------------------------------
    -- compare
    ------------------------------------------------------------------
    local needs_update = false

    if remote_date      and local_date      and remote_date      > local_date      then needs_update = true end
    if remote_words     and local_words     and remote_words     ~= local_words     then needs_update = true end
    if remote_chapters  and local_chapters  and remote_chapters  ~= local_chapters  then needs_update = true end

    -- fallback: if we couldn’t parse words/chapters locally, fall back to date only
    if not (local_words and local_chapters) and remote_date > local_date then needs_update = true end

    ------------------------------------------------------------------
    -- fetch & replace
    ------------------------------------------------------------------
    if needs_update then
        self:log(string.format("Updating %s (local %s w/%s ch, remote %s w/%s ch)",
            epub, tostring(local_words), tostring(local_chapters), tostring(remote_words), tostring(remote_chapters)))

        local tmp = epub .. ".tmp"
        local f   = io.open(tmp, "wb")
        if f then
            local ok_dl, dl_code = https.request{
                url      = download_url,
                sink     = ltn12.sink.file(f),
                protocol = "tlsv1_2",
                options  = "all",
                verify   = "none"
            }
            if ok_dl then
                os.remove(epub)
                os.rename(tmp, epub)
                self:log("Replaced: " .. epub)
                self.updated_files[#self.updated_files+1] = epub:match("[^/]+$")
            else
                self:log("Download failed, code=" .. tostring(dl_code))
                os.remove(tmp)
            end
        end
    end
end

--------------------------------------------------------------------------
-- main driver: scan directories, process each epub
--------------------------------------------------------------------------
function AO3Updater:run_update()
    self:log("--- Starting update ---")
    self.updated_files = {}

    -- ensure the system has 'unzip'
    local chk = io.popen("unzip -v 2>&1")
    if not chk then
        self:log("unzip not available")
        UIManager:show(InfoMessage:new{ text = _("`unzip` not available") })
        return {}
    end
    chk:close()

    -- dynamic deps
    local ok_lfs, lfs        = pcall(require, "lfs")
    local ok_https, https    = pcall(require, "ssl.https")
    local ok_ltn12, ltn12    = pcall(require, "ltn12")

    if not (ok_lfs and ok_https and ok_ltn12) then
        local missing = {}
        if not ok_lfs   then missing[#missing+1] = "lfs"   end
        if not ok_https then missing[#missing+1] = "ssl.https" end
        if not ok_ltn12 then missing[#missing+1] = "ltn12"     end
        local msg = _("Missing modules: ") .. table.concat(missing, ", ")
        self:log(msg)
        UIManager:show(InfoMessage:new{ text = msg })
        return {}
    end

    if https.TIMEOUT then https.TIMEOUT = 10; self:log("HTTPS timeout set to 10") end

    if not self.default_dir or self.default_dir == "" then
        self:log("No default directory set")
        UIManager:show(InfoMessage:new{ text = _("No default directory set. Please set it in plugin settings.") })
        return {}
    end

    -- collect epub paths
    local epubs, roots = {}, { self.default_dir }
    local function find_epubs(dir)
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local path = dir .. "/" .. entry
                local attr = lfs.attributes(path)
                if attr then
                    if attr.mode == "directory" then
                        find_epubs(path)
                    elseif entry:lower():match("%.epub$") then
                        epubs[#epubs+1] = path
                    end
                end
            end
        end
    end
    find_epubs(self.default_dir)

    self:log("Found " .. #epubs .. " EPUB(s)")

    for _, epub in ipairs(epubs) do
        self:log("Processing " .. epub)
        self:process_epub(epub, https, ltn12)
    end

    self:log("--- Update completed ---")
    return self.updated_files
end

return AO3Updater
