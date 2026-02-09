local Path = require("plenary.path")

local M = {}

--- Get base data path for all annotations
--- @return string
function M.get_data_path()
    return vim.fn.stdpath("data") .. "/annotate"
end

--- Build audit session path
--- @param host string e.g., "github.com"
--- @param owner string e.g., "ethereum"
--- @param repo string e.g., "solidity"
--- @param commit string e.g., "abc123d"
--- @return string full path to session directory
function M.get_session_path(host, owner, repo, commit)
    return string.format("%s/%s/%s/%s/%s", 
        M.get_data_path(), host, owner, repo, commit)
end

--- Ensure directory structure exists
--- @param session_path string
function M.ensure_session_dir(session_path)
    local path = Path:new(session_path)
    if not path:exists() then
        path:mkdir({parents = true})
    end
end

--- Load notes.json for current session
--- @param session_path string
--- @return table notes data with structure {version, notes=[]}
function M.load_notes(session_path)
    local notes_file = session_path .. "/notes.json"
    local path = Path:new(notes_file)
    
    if not path:exists() then
        return {version = "1.0", notes = {}}
    end
    
    local content = path:read()
    if not content or content == "" then
        return {version = "1.0", notes = {}}
    end
    
    local ok, data = pcall(vim.json.decode, content)
    if not ok then
        vim.notify("Failed to parse notes.json: " .. notes_file, vim.log.levels.ERROR)
        return {version = "1.0", notes = {}}
    end
    
    return data
end

--- Save notes.json
--- @param session_path string
--- @param notes_data table with structure {version, notes=[]}
function M.save_notes(session_path, notes_data)
    local notes_file = session_path .. "/notes.json"
    
    local ok, encoded = pcall(vim.json.encode, notes_data)
    if not ok then
        error("Failed to encode notes data: " .. encoded)
    end
    
    Path:new(notes_file):write(encoded, "w")
end

--- Load metadata.json
--- @param session_path string
--- @return table|nil metadata or nil if doesn't exist
function M.load_metadata(session_path)
    local metadata_file = session_path .. "/metadata.json"
    local path = Path:new(metadata_file)
    
    if not path:exists() then
        return nil
    end
    
    local content = path:read()
    if not content or content == "" then
        return nil
    end
    
    local ok, data = pcall(vim.json.decode, content)
    if not ok then
        vim.notify("Failed to parse metadata.json: " .. metadata_file, vim.log.levels.ERROR)
        return nil
    end
    
    return data
end

--- Save metadata.json
--- @param session_path string
--- @param metadata table
function M.save_metadata(session_path, metadata)
    local metadata_file = session_path .. "/metadata.json"
    
    local ok, encoded = pcall(vim.json.encode, metadata)
    if not ok then
        error("Failed to encode metadata: " .. encoded)
    end
    
    Path:new(metadata_file):write(encoded, "w")
end

--- Initialize new audit session
--- Creates directories and metadata.json with initial data
--- @param host string
--- @param owner string
--- @param repo string
--- @param commit string
--- @param repo_root string
--- @param repo_url string
--- @return string session_path
function M.init_session(host, owner, repo, commit, repo_root, repo_url)
    local session_path = M.get_session_path(host, owner, repo, commit)
    M.ensure_session_dir(session_path)

    local metadata = {
        repo_url = repo_url,
        repo_root = repo_root,
        base_ref = commit,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        last_modified = os.date("!%Y-%m-%dT%H:%M:%SZ")
    }

    M.save_metadata(session_path, metadata)
    M.save_notes(session_path, {version = "1.0", notes = {}})

    return session_path
end

--- Check if a session has no notes
--- @param session_path string
--- @return boolean
local function is_session_empty(session_path)
    local notes_data = M.load_notes(session_path)
    return #notes_data.notes == 0
end

--- Remove a session directory and all its contents
--- @param session_path string
local function remove_session_dir(session_path)
    local handle = vim.loop.fs_scandir(session_path)
    if handle then
        while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            local full_path = session_path .. "/" .. name
            if type == "directory" then
                remove_session_dir(full_path)
            else
                vim.loop.fs_unlink(full_path)
            end
        end
    end
    vim.loop.fs_rmdir(session_path)
end

--- Clean up empty audit sessions for a repository
--- @param base_path string base annotate data path
--- @param host string
--- @param owner string
--- @param repo string
--- @return number count of removed sessions
function M.clean_empty_sessions(base_path, host, owner, repo)
    local Path = require("plenary.path")
    local repo_path = string.format("%s/%s/%s/%s", base_path, host, owner, repo)
    local path = Path:new(repo_path)

    if not path:exists() then
        return 0
    end

    local removed_count = 0
    local handle = vim.loop.fs_scandir(repo_path)
    if handle then
        while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            if type == "directory" then
                local session_path = repo_path .. "/" .. name
                if is_session_empty(session_path) then
                    remove_session_dir(session_path)
                    removed_count = removed_count + 1
                end
            end
        end
    end

    return removed_count
end

--- Recursively remove empty directories
--- @param path string
local function remove_empty_dirs(path)
    local Path = require("plenary.path")
    local p = Path:new(path)

    if not p:exists() then
        return
    end

    local handle = vim.loop.fs_scandir(path)
    if handle then
        local is_empty = true
        while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            local full_path = path .. "/" .. name
            if type == "directory" then
                remove_empty_dirs(full_path)
                -- Check if directory still exists (wasn't removed)
                if Path:new(full_path):exists() then
                    is_empty = false
                end
            else
                is_empty = false
            end
        end

        if is_empty then
            vim.loop.fs_rmdir(path)
        end
    end
end

--- Clean all empty sessions and remove empty directory structure
--- @param base_path string
function M.clean_all_empty(base_path)
    local Path = require("plenary.path")
    local path = Path:new(base_path)

    if not path:exists() then
        return 0
    end

    -- Find all sessions and remove empty ones
    local removed_count = 0

    local function scan_for_sessions(current_path)
        local handle = vim.loop.fs_scandir(current_path)
        if not handle then return end

        while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            local full_path = current_path .. "/" .. name

            if type == "directory" then
                -- Check if this looks like a session (contains notes.json)
                local notes_file = full_path .. "/notes.json"
                if Path:new(notes_file):exists() then
                    -- This is a session directory
                    if is_session_empty(full_path) then
                        remove_session_dir(full_path)
                        removed_count = removed_count + 1
                    end
                else
                    -- Recurse into subdirectories
                    scan_for_sessions(full_path)
                end
            end
        end
    end

    scan_for_sessions(base_path)

    -- Clean up empty directory structure
    remove_empty_dirs(base_path)

    return removed_count
end

return M
