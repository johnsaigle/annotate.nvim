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

return M
