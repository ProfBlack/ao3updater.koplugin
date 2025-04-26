-- main.lua
-- AO3Updater: KOReader plugin, updates AO3 EPUBs with SSL HTTP requests

local InfoMessage     = require("ui/widget/infomessage")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("gettext")

-- Add socket for sleep() when handling non-blocking SSL
local socket          = require("socket")
-- UI and settings dependencies
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local PathChooser     = require("ui/widget/pathchooser")

local AO3Updater = WidgetContainer:extend({ name = "ao3updater", is_doc_only = false })

function AO3Updater:init()
    -- Determine plugin directory for log file
    local src = debug.getinfo(1, "S").source or ""
    local plugin_dir = src:match("@(.+)/[^/]+$") or "."
    self.plugin_dir = plugin_dir
    self.log_file    = plugin_dir .. "/ao3updater.log"
    -- Load settings file
    self.settings_file = DataStorage:getSettingsDir() .. "/ao3updater.lua"
    self.settings      = LuaSettings:open(self.settings_file)
    self.default_dir   = self.settings:readSetting("default_dir")
    -- Register plugin under "More Tools"
    if self.ui.menu       then self.ui.menu:registerToMainMenu(self) end
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
                    text     = _("Update AO3 EPUBs"),
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
                                UIManager:show(InfoMessage:new{
                                    text = _("Update complete. Updated: ") .. table.concat(updated, ", ")
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Update complete. No EPUBs were updated.")
                                })
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

function AO3Updater:run_update()
    self:log("--- Starting update ---")
    self.updated_files = {}
    -- Check unzip binary
    local chk = io.popen("unzip -v 2>&1")
    if not chk then
        self:log("unzip not available")
        UIManager:show(InfoMessage:new{ text = _("`unzip` not available") })
        return {}
    end
    chk:close()

    -- Load dependencies
    local ok_lfs,   lfs    = pcall(require, "lfs")
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn12, ltn12  = pcall(require, "ltn12")
    if not(ok_lfs and ok_https and ok_ltn12) then
        local missing = {}
        if not ok_lfs   then table.insert(missing, "lfs") end
        if not ok_https then table.insert(missing, "ssl.https") end
        if not ok_ltn12 then table.insert(missing, "ltn12") end
        local msg = _("Missing modules: ") .. table.concat(missing, ", ")
        self:log(msg)
        UIManager:show(InfoMessage:new{ text = msg })
        return {}
    end
    -- Set timeout
    if https.TIMEOUT then https.TIMEOUT = 10; self:log("HTTPS timeout set to " .. tostring(https.TIMEOUT)) end

    -- Require user-defined directory
    if not self.default_dir or self.default_dir == "" then
        self:log("No default directory set")
        UIManager:show(InfoMessage:new{ text = _("No default directory set. Please set it in plugin settings.") })
        return {}
    end
    local roots = { self.default_dir }

    local epubs = {}
    for _, root in ipairs(roots) do
        local attr = lfs.attributes(root)
        if attr and attr.mode == "directory" then
            self:log("Scanning root: " .. root)
            self:find_epubs(root, epubs, lfs)
        else
            self:log("Skipping root: " .. tostring(root))
        end
    end
    self:log("Found " .. #epubs .. " EPUB(s)")
    for _, epub in ipairs(epubs) do
        self:log("Processing " .. epub)
        self:process_epub(epub, https, ltn12)
    end
    self:log("--- Update completed ---")
    return self.updated_files
end

function AO3Updater:find_epubs(dir, results, lfs)
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "directory" then
                    self:find_epubs(path, results, lfs)
                elseif entry:lower():match("%.epub$") then
                    table.insert(results, path)
                end
            end
        end
    end
end

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
    local c = ""
    if p then c = p:read("*a"); p:close() end
    return c
end

function AO3Updater:get_epub_date_and_url(epub)
    local date_local, ao3_url
    for _, fn in ipairs(list_xhtml(epub)) do
        local raw     = get_content(epub, fn)
        local content = raw:gsub("%s+", " ")
        date_local = date_local
            or content:match("Updated:%s*([0-9][0-9][0-9][0-9]%-[0-9][0-9]%-[0-9][0-9])")
            or content:match("Completed:%s*([0-9][0-9][0-9][0-9]%-[0-9][0-9]%-[0-9][0-9])")
        ao3_url    = ao3_url
            or content:match("(https?://archiveofourown.org/works/%d+)")
        if date_local and ao3_url then break end
    end
    if ao3_url then ao3_url = ao3_url:gsub("^http://", "https://") end
    self:log("Local date: " .. tostring(date_local) .. ", URL: " .. tostring(ao3_url))
    return date_local, ao3_url
end

function AO3Updater:get_remote_info(ao3_url, https, ltn12)
    local max_retries, retries = 69, 0
    local ok, code, headers, status, resp
    repeat
        resp = {}
        ok, code, headers, status = https.request{
            url      = ao3_url,
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
        else break end
    until false

    local body = table.concat(resp)
    self:log(string.format("Fetched %d bytes, code=%s", #body, tostring(code)))
    if code ~= 200 or body == "" then
        self:log("--- DEBUG: non-200 response body start ---")
        self:log(body:sub(1,512))
        self:log("--- DEBUG: non-200 response body end ---")
        return nil, nil
    end

    local remote_date = body:match("<dt[^>]->%s*Updated:%s*</dt>%s*<dd[^>]->%s*(%d%d%d%d%-%d%d%-%d%d)%s*</dd>")
                     or body:match("<dt[^>]->%s*Completed:%s*</dt>%s*<dd[^>]->%s*(%d%d%d%d%-%d%d%-%d%d)%s*</dd>")
    local raw_dl = body:match('href="([^"]+%.epub[^"]*)"')
    local download_url
    if raw_dl then
        if raw_dl:match("^https?://") then download_url = raw_dl
        else download_url = "https://archiveofourown.org" .. raw_dl end
    end

    self:log(string.format("Remote date=%s, download_url=%s", tostring(remote_date), tostring(download_url)))
    return remote_date, download_url
end

function AO3Updater:process_epub(epub, https, ltn12)
    local local_date, ao3_url = self:get_epub_date_and_url(epub)
    if not(local_date and ao3_url) then return end

    local remote_date, download_url = self:get_remote_info(ao3_url, https, ltn12)
    if not remote_date then return end
    if not download_url then
        self:log("No download URL found for " .. ao3_url)
        return
    end

    if remote_date > local_date then
        self:log("Updating " .. epub)
        local tmp = epub .. ".tmp"
        local f = io.open(tmp, "wb")
        if f then
            local ok_dl, dl_code = https.request{ url = download_url, sink = ltn12.sink.file(f), protocol = "tlsv1_2", options = "all", verify = "none" }
            if ok_dl then
                os.remove(epub)
                os.rename(tmp, epub)
                self:log("Replaced: " .. epub)
                table.insert(self.updated_files, epub:match("[^/]+$"))
            else
                self:log("Download failed, code=" .. tostring(dl_code))
                os.remove(tmp)
            end
        end
    end
end

return AO3Updater
