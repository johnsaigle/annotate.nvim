local M = {}

--- Check if current directory is inside a git repository
--- @return boolean
function M.is_git_repo()
    local result = vim.fn.system("git rev-parse --is-inside-work-tree 2>/dev/null")
    return vim.v.shell_error == 0 and result:match("true") ~= nil
end

--- Get the git repository root directory
--- @return string|nil path to repo root or nil if not in git repo
function M.get_repo_root()
    if not M.is_git_repo() then
        return nil
    end
    
    local result = vim.fn.system("git rev-parse --show-toplevel")
    if vim.v.shell_error ~= 0 then
        return nil
    end
    
    -- Trim newline
    return result:gsub("\n", "")
end

--- Get the current HEAD commit hash (short)
--- @return string|nil 7-character commit hash or nil
function M.get_head_commit()
    if not M.is_git_repo() then
        return nil
    end
    
    local result = vim.fn.system("git rev-parse --short=7 HEAD")
    if vim.v.shell_error ~= 0 then
        return nil
    end
    
    -- Trim newline
    return result:gsub("\n", "")
end

--- Get the remote origin URL
--- @return string|nil URL or nil
function M.get_remote_url()
    if not M.is_git_repo() then
        return nil
    end
    
    local result = vim.fn.system("git remote get-url origin 2>/dev/null")
    if vim.v.shell_error ~= 0 then
        return nil
    end
    
    -- Trim newline
    return result:gsub("\n", "")
end

--- Parse git URL into host, owner, repo
--- Handles both HTTPS and SSH formats:
---   https://github.com/ethereum/solidity.git
---   git@github.com:ethereum/solidity.git
--- @param url string
--- @return table|nil {host, owner, repo} or nil on parse error
function M.parse_git_url(url)
    if not url or url == "" then
        return nil
    end
    
    local host, owner, repo
    
    -- Try HTTPS format: https://host/owner/repo.git
    host, owner, repo = url:match("https?://([^/]+)/([^/]+)/([^/]+)")
    
    -- Try SSH format: git@host:owner/repo.git
    if not host then
        host, owner, repo = url:match("git@([^:]+):([^/]+)/([^/]+)")
    end
    
    if not host or not owner or not repo then
        return nil
    end
    
    -- Remove .git suffix if present
    repo = repo:gsub("%.git$", "")
    
    return {
        host = host,
        owner = owner,
        repo = repo
    }
end

--- Get file path relative to repo root
--- @param absolute_path string
--- @param repo_root string
--- @return string relative path
function M.get_relative_path(absolute_path, repo_root)
    -- Normalize both paths
    absolute_path = vim.fn.fnamemodify(absolute_path, ":p")
    repo_root = vim.fn.fnamemodify(repo_root, ":p")
    
    -- Ensure repo_root ends with /
    if not repo_root:match("/$") then
        repo_root = repo_root .. "/"
    end
    
    -- Remove repo_root prefix
    if absolute_path:sub(1, #repo_root) == repo_root then
        return absolute_path:sub(#repo_root + 1)
    end
    
    -- Fallback to just the filename if not in repo
    return vim.fn.fnamemodify(absolute_path, ":t")
end

--- Find existing audit sessions for a given repo
--- @param base_path string base annotate data path
--- @param host string
--- @param owner string
--- @param repo string
--- @return table array of commit hashes
function M.find_existing_audits(base_path, host, owner, repo)
    local Path = require("plenary.path")
    local repo_path = string.format("%s/%s/%s/%s", base_path, host, owner, repo)
    local path = Path:new(repo_path)
    
    if not path:exists() then
        return {}
    end
    
    local audits = {}
    for _, entry in ipairs(path:readdir()) do
        local name = vim.fn.fnamemodify(entry, ":t")
        table.insert(audits, name)
    end
    
    return audits
end

return M
