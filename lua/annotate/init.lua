local git = require("annotate.git")
local storage = require("annotate.storage")
local Highlights = require("annotate.highlights")

local M = {}

---@class AnnotateSession
---@field path string session directory path
---@field repo_root string absolute path to repo root
---@field host string e.g., "github.com"
---@field owner string e.g., "ethereum"
---@field repo string e.g., "solidity"
---@field commit string 7-char commit hash
---@field highlights AnnotateHighlights

---@type table<string, AnnotateSession>
local sessions = {}

local augroup = vim.api.nvim_create_augroup
local AnnotateGroup = augroup("AnnotateGroup", {})
local autocmd = vim.api.nvim_create_autocmd

--- Get current file's buffer name
--- @return string
local function get_current_name()
    return vim.api.nvim_buf_get_name(0)
end

--- Get or create session for current file
--- @param create_if_missing boolean whether to create session if it doesn't exist
--- @return AnnotateSession|nil
local function get_current_session(create_if_missing)
    local current_file = get_current_name()

    -- Check if we already have a session for this file
    if sessions[current_file] then
        return sessions[current_file]
    end

    -- Check if in git repo
    if not git.is_git_repo() then
        return nil
    end

    -- Get git info
    local repo_root = git.get_repo_root()
    local remote_url = git.get_remote_url()
    local head_commit = git.get_head_commit()

    if not repo_root then
        vim.notify("Failed to get git repository root.", vim.log.levels.ERROR)
        return nil
    end

    if not remote_url then
        vim.notify("No git remote found. Annotate requires a remote origin.", vim.log.levels.ERROR)
        return nil
    end

    if not head_commit then
        vim.notify("Failed to get git HEAD commit.", vim.log.levels.ERROR)
        return nil
    end

    -- Parse git URL
    local parsed = git.parse_git_url(remote_url)
    if not parsed then
        vim.notify("Failed to parse git remote URL: " .. remote_url, vim.log.levels.ERROR)
        return nil
    end

    local host, owner, repo = parsed.host, parsed.owner, parsed.repo

    -- Check if session exists for this commit
    local session_path = storage.get_session_path(host, owner, repo, head_commit)
    local session_exists = require("plenary.path"):new(session_path):exists()

    -- Only create session directory on "add" action, not on init
    if not session_exists then
        if not create_if_missing then
            return nil
        end

        -- Check for other audit sessions
        local existing_audits = git.find_existing_audits(
            storage.get_data_path(), host, owner, repo
        )

        if #existing_audits > 0 then
            -- Use echo instead of notify to avoid "Press ENTER" prompt
            vim.cmd(string.format(
                'echom "Creating new audit session for commit %s. Found %d existing audit(s) at: %s"',
                head_commit,
                #existing_audits,
                table.concat(existing_audits, ", ")
            ))
        end

        session_path = storage.init_session(host, owner, repo, head_commit,
                                           repo_root, remote_url)
    end

    -- Load notes and create highlights
    local notes_data = storage.load_notes(session_path)
    local relative_file = git.get_relative_path(current_file, repo_root)
    local highlights = Highlights.AnnotateHighlights:new(notes_data.notes, relative_file)

    -- Create session
    local session = {
        path = session_path,
        repo_root = repo_root,
        host = host,
        owner = owner,
        repo = repo,
        commit = head_commit,
        highlights = highlights,
        relative_file = relative_file,
    }

    sessions[current_file] = session
    return session
end

--- Setup function - define signs and autocmds
function M.setup()
    -- Define signs for each type with emoji
    vim.fn.sign_define("AnnotateFinding", {
        text = '🔴',
        texthl = 'AnnotateFinding'
    })
    
    vim.fn.sign_define("AnnotateQuestion", {
        text = '🟡',
        texthl = 'AnnotateQuestion'
    })
    
    vim.fn.sign_define("AnnotateSafe", {
        text = '🟢',
        texthl = 'AnnotateSafe'
    })
    
    vim.fn.sign_define("AnnotateSuggestion", {
        text = '🔵',
        texthl = 'AnnotateSuggestion'
    })
    
    vim.fn.sign_define("AnnotateComment", {
        text = '⚪',
        texthl = 'AnnotateComment'
    })
    
    vim.fn.sign_define("AnnotateInvariant", {
        text = '🟣',
        texthl = 'AnnotateInvariant'
    })
    
    -- Define highlight colors
    vim.cmd [[highlight AnnotateFinding guifg=#FF6B6B]]
    vim.cmd [[highlight AnnotateQuestion guifg=#FFD93D]]
    vim.cmd [[highlight AnnotateSafe guifg=#6BCF7F]]
    vim.cmd [[highlight AnnotateSuggestion guifg=#4ECDC4]]
    vim.cmd [[highlight AnnotateComment guifg=#AAAAAA]]
    vim.cmd [[highlight AnnotateInvariant guifg=#9B59B6]]
    
    -- Refresh highlights on buffer enter
    autocmd({"BufEnter"}, {
        group = AnnotateGroup,
        pattern = "*",
        callback = function()
            local session = get_current_session()
            if session then
                session.highlights:refresh_highlights()
            end
        end
    })
end

--- Helper to calculate statistics
--- @param notes AnnotateNote[]
--- @return table stats by type
local function calculate_stats(notes)
    local stats = {
        finding = 0,
        question = 0,
        safe = 0,
        suggestion = 0,
        comment = 0,
        invariant = 0
    }

    for _, note in ipairs(notes) do
        stats[note.type] = (stats[note.type] or 0) + 1
    end

    return stats
end

--- Add a note with type and text
--- @param note_type string
--- @param text string
function M.add_note(note_type, text)
    local session = get_current_session(true)  -- Create session if needed
    if not session then
        return
    end
    
    local parts = vim.fn.getpos(".")
    local line = parts[2]
    
    local note = {
        file = session.relative_file,
        line = line,
        type = note_type,
        text = text,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        commit = session.commit
    }
    
    -- Load existing notes
    local notes_data = storage.load_notes(session.path)
    table.insert(notes_data.notes, note)
    
    -- Sort by file, then line
    table.sort(notes_data.notes, function(a, b)
        if a.file == b.file then
            return a.line < b.line
        end
        return a.file < b.file
    end)
    
    -- Save
    storage.save_notes(session.path, notes_data)
    
    -- Update metadata timestamp
    local metadata = storage.load_metadata(session.path)
    metadata.last_modified = os.date("!%Y-%m-%dT%H:%M:%SZ")
    storage.save_metadata(session.path, metadata)
    
    -- Refresh highlights
    session.highlights = Highlights.AnnotateHighlights:new(
        notes_data.notes, session.relative_file
    )
    session.highlights:refresh_highlights()
end

--- Add note with type selection menu
function M.add()
    -- Show selection menu
    vim.ui.select(
        {'finding', 'question', 'safe', 'suggestion', 'comment', 'invariant'},
        {
            prompt = 'Select note type:',
            format_item = function(item)
                local icons = {
                    finding = '🔴 Finding',
                    question = '🟡 Question',
                    safe = '🟢 Safe',
                    suggestion = '🔵 Suggestion',
                    comment = '⚪ Comment',
                    invariant = '🟣 Invariant'
                }
                return icons[item]
            end
        },
        function(choice)
            if not choice then
                return  -- User cancelled
            end

            -- Get note text
            local text = vim.fn.input({prompt = "Note: "})
            if text == "" then
                return  -- User cancelled or empty input
            end

            -- Add the note
            M.add_note(choice, text)
        end
    )
end

--- Remove note at cursor
function M.rm()
    local session = get_current_session()
    if not session then
        return
    end
    
    local parts = vim.fn.getpos(".")
    local line = parts[2]
    
    -- Load all notes
    local notes_data = storage.load_notes(session.path)
    
    -- Find notes at this line in this file
    local notes_at_line = {}
    for i, note in ipairs(notes_data.notes) do
        if note.file == session.relative_file and note.line == line then
            table.insert(notes_at_line, {index = i, note = note})
        end
    end
    
    if #notes_at_line == 0 then
        return
    end
    
    -- Close any open floating window before deleting
    session.highlights:close_notes()
    
    -- If only one note, delete it directly
    if #notes_at_line == 1 then
        table.remove(notes_data.notes, notes_at_line[1].index)
    else
        -- Multiple notes - let user choose which to delete
        local items = {}
        for i, item in ipairs(notes_at_line) do
            local note = item.note
            local preview = note.text:sub(1, 40)
            if #note.text > 40 then
                preview = preview .. "..."
            end
            table.insert(items, {
                index = i,
                note_index = item.index,
                display = string.format("[%s] %s", note.type:upper(), preview),
                note = note
            })
        end
        
        -- Add "Delete all" option
        table.insert(items, 1, {
            index = 0,
            note_index = nil,
            display = "🗑️  Delete ALL notes on this line",
            delete_all = true
        })
        
        vim.ui.select(items, {
            prompt = string.format("Select note to delete (%d found):", #notes_at_line),
            format_item = function(item)
                return item.display
            end
        }, function(choice)
            if not choice then
                return  -- User cancelled
            end
            
            if choice.delete_all then
                -- Delete all notes on this line (iterate backwards to maintain indices)
                for i = #notes_at_line, 1, -1 do
                    table.remove(notes_data.notes, notes_at_line[i].index)
                end
            else
                -- Delete selected note
                table.remove(notes_data.notes, choice.note_index)
            end
            
            -- Save
            storage.save_notes(session.path, notes_data)
            
            -- Update metadata timestamp
            local metadata = storage.load_metadata(session.path)
            metadata.last_modified = os.date("!%Y-%m-%dT%H:%M:%SZ")
            storage.save_metadata(session.path, metadata)
            
            -- Refresh highlights
            session.highlights = Highlights.AnnotateHighlights:new(
                notes_data.notes, session.relative_file
            )
            session.highlights:refresh_highlights()
            
            vim.notify("Note(s) deleted", vim.log.levels.INFO)
        end)
        
        return  -- Async callback handles the rest
    end
    
    -- Save
    storage.save_notes(session.path, notes_data)
    
    -- Update metadata timestamp
    local metadata = storage.load_metadata(session.path)
    metadata.last_modified = os.date("!%Y-%m-%dT%H:%M:%SZ")
    storage.save_metadata(session.path, metadata)
    
    -- Refresh highlights
    session.highlights = Highlights.AnnotateHighlights:new(
        notes_data.notes, session.relative_file
    )
    session.highlights:refresh_highlights()
    
    vim.notify("Note deleted", vim.log.levels.INFO)
end

--- Remove all notes in current file
function M.rm_all()
    local session = get_current_session()
    if not session then
        return
    end
    
    -- Confirm
    local confirm = vim.fn.input("Remove all notes in this file? (y/n): ")
    if confirm:lower() ~= "y" then
        return
    end
    
    -- Load all notes
    local notes_data = storage.load_notes(session.path)
    
    -- Remove notes for this file
    local removed_count = 0
    for i = #notes_data.notes, 1, -1 do
        local note = notes_data.notes[i]
        if note.file == session.relative_file then
            table.remove(notes_data.notes, i)
            removed_count = removed_count + 1
        end
    end
    
    if removed_count == 0 then
        return
    end
    
    -- Save
    storage.save_notes(session.path, notes_data)
    
    -- Update metadata timestamp
    local metadata = storage.load_metadata(session.path)
    metadata.last_modified = os.date("!%Y-%m-%dT%H:%M:%SZ")
    storage.save_metadata(session.path, metadata)
    
    -- Refresh highlights
    session.highlights = Highlights.AnnotateHighlights:new(
        notes_data.notes, session.relative_file
    )
    session.highlights:refresh_highlights()
end

--- Navigate to next note
function M.nav_next()
    local session = get_current_session()
    if session then
        session.highlights:nav_next()
    end
end

--- Show notes at cursor
function M.show_notes()
    local session = get_current_session()
    if session then
        session.highlights:show_notes()
    end
end

--- Show next note (navigate + show)
function M.show_next()
    M.nav_next()
    M.show_notes()
end

--- Generate GitHub permalink for a file and line
--- @param host string e.g., "github.com"
--- @param owner string e.g., "ethereum"
--- @param repo string e.g., "solidity"
--- @param commit string commit hash
--- @param file string relative file path
--- @param line number line number
--- @return string|nil permalink URL or nil if not GitHub/GitLab
local function generate_permalink(host, owner, repo, commit, file, line)
    -- Only generate for GitHub and GitLab
    if host == "github.com" then
        return string.format("https://github.com/%s/%s/blob/%s/%s#L%d",
                           owner, repo, commit, file, line)
    elseif host == "gitlab.com" then
        return string.format("https://gitlab.com/%s/%s/-/blob/%s/%s#L%d",
                           owner, repo, commit, file, line)
    end
    
    return nil
end

--- Export all notes to markdown
--- @param filepath string|nil output path (defaults to ./audit-report.md)
function M.export(filepath)
    local session = get_current_session()
    if not session then
        return
    end
    
    -- Default output path
    local output_path = filepath or "./audit-report.md"
    
    -- Load all notes
    local notes_data = storage.load_notes(session.path)
    local metadata = storage.load_metadata(session.path)
    
    -- Generate markdown
    local lines = {}
    
    -- Header
    table.insert(lines, string.format("# Audit Report: %s/%s", 
                                      session.owner, session.repo))
    table.insert(lines, string.format("Ref: %s", metadata.base_ref))
    table.insert(lines, string.format("Started: %s", 
                                      metadata.created_at:sub(1, 10)))
    table.insert(lines, string.format("Last Updated: %s", 
                                      metadata.last_modified:sub(1, 10)))
    table.insert(lines, "")
    
    -- Summary statistics
    local stats = calculate_stats(notes_data.notes)
    table.insert(lines, "## Summary")
    table.insert(lines, string.format("- %d Findings", stats.finding))
    table.insert(lines, string.format("- %d Questions", stats.question))
    table.insert(lines, string.format("- %d Marked Safe", stats.safe))
    table.insert(lines, string.format("- %d Suggestions", stats.suggestion))
    table.insert(lines, string.format("- %d Comments", stats.comment))
    table.insert(lines, string.format("- %d Invariants", stats.invariant))
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
    
    -- Group notes by type
    local by_type = {
        finding = {},
        question = {},
        safe = {},
        suggestion = {},
        comment = {},
        invariant = {}
    }
    
    for _, note in ipairs(notes_data.notes) do
        table.insert(by_type[note.type], note)
    end
    
    -- Sort notes within each type by file, then line
    for _, notes in pairs(by_type) do
        table.sort(notes, function(a, b)
            if a.file == b.file then
                return a.line < b.line
            end
            return a.file < b.file
        end)
    end
    
    -- Output notes by type in priority order
    local type_order = {
        {key = "finding", label = "Findings", icon = "🔴"},
        {key = "question", label = "Questions", icon = "🟡"},
        {key = "suggestion", label = "Suggestions", icon = "🔵"},
        {key = "safe", label = "Marked Safe", icon = "🟢"},
        {key = "comment", label = "Comments", icon = "⚪"},
        {key = "invariant", label = "Invariants", icon = "🟣"},
    }
    
    for _, type_info in ipairs(type_order) do
        local notes = by_type[type_info.key]
        
        if #notes > 0 then
            table.insert(lines, string.format("## %s %s", type_info.icon, type_info.label))
            table.insert(lines, "")
            
            for _, note in ipairs(notes) do
                -- Generate permalink
                local permalink = generate_permalink(
                    session.host, session.owner, session.repo,
                    note.commit, note.file, note.line
                )
                
                if permalink then
                    table.insert(lines, string.format("### %s:%d", note.file, note.line))
                    table.insert(lines, string.format("**Link:** %s", permalink))
                else
                    table.insert(lines, string.format("### %s:%d", note.file, note.line))
                end
                
                table.insert(lines, string.format("Added: %s", 
                                                  note.created_at:sub(1, 10)))
                table.insert(lines, "")
                table.insert(lines, note.text)
                table.insert(lines, "")
                table.insert(lines, "---")
                table.insert(lines, "")
            end
        end
    end
    
    -- Write to file
    local output = table.concat(lines, "\n")
    local file_handle = io.open(output_path, "w")
    if not file_handle then
        vim.notify("Failed to write export file: " .. output_path, vim.log.levels.ERROR)
        return
    end
    
    file_handle:write(output)
    file_handle:close()
    
    -- Use echo instead of notify to avoid "Press ENTER" prompt
    vim.cmd(string.format('echo "Exported %d notes to %s"', 
                         #notes_data.notes, output_path))
end

--- Show audit session statistics
function M.stats()
    local session = get_current_session()
    if not session then
        return
    end

    -- Load all notes for the audit session
    local notes_data = storage.load_notes(session.path)
    local metadata = storage.load_metadata(session.path)

    -- Calculate statistics
    local stats = calculate_stats(notes_data.notes)

    -- Count unique files
    local files = {}
    for _, note in ipairs(notes_data.notes) do
        files[note.file] = true
    end
    local file_count = 0
    for _ in pairs(files) do
        file_count = file_count + 1
    end

    -- Build display message
    local lines = {
        string.format("Audit Session: %s/%s/%s",
                      session.host, session.owner, session.repo),
        string.format("Commit: %s", session.commit),
        string.format("Started: %s", metadata.created_at:sub(1, 10)),
        "",
        string.format("Total Notes: %d", #notes_data.notes),
        string.format("Files Annotated: %d", file_count),
        "",
        "By Type:",
        string.format("  Findings:    %d", stats.finding),
        string.format("  Questions:   %d", stats.question),
        string.format("  Safe:        %d", stats.safe),
        string.format("  Suggestions: %d", stats.suggestion),
        string.format("  Comments:    %d", stats.comment),
        string.format("  Invariants:  %d", stats.invariant),
    }

    -- Display in a floating window
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local width = 50
    local height = #lines
    local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = 'minimal',
        border = 'rounded',
        title = ' Audit Statistics ',
        title_pos = 'center'
    })

    -- Close on any key press
    vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>',
                                {nowait = true, noremap = true, silent = true})
    vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':close<CR>',
                                {nowait = true, noremap = true, silent = true})
    vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', ':close<CR>',
                                {nowait = true, noremap = true, silent = true})
end

--- Clean empty audit sessions for current repository
function M.clean()
    local current_file = get_current_name()
    local session = sessions[current_file]

    if not session then
        -- Try to get basic git info without creating a session
        if not git.is_git_repo() then
            vim.notify("Not in a git repository.", vim.log.levels.ERROR)
            return
        end

        local repo_root = git.get_repo_root()
        local remote_url = git.get_remote_url()

        if not repo_root or not remote_url then
            vim.notify("Failed to get repository information.", vim.log.levels.ERROR)
            return
        end

        local parsed = git.parse_git_url(remote_url)
        if not parsed then
            vim.notify("Failed to parse git remote URL.", vim.log.levels.ERROR)
            return
        end

        local base_path = storage.get_data_path()
        local removed = storage.clean_empty_sessions(base_path, parsed.host, parsed.owner, parsed.repo)

        vim.notify(string.format("Cleaned %d empty audit session(s) for %s/%s", removed, parsed.owner, parsed.repo), vim.log.levels.INFO)
    else
        local base_path = storage.get_data_path()
        local removed = storage.clean_empty_sessions(base_path, session.host, session.owner, session.repo)

        vim.notify(string.format("Cleaned %d empty audit session(s) for %s/%s", removed, session.owner, session.repo), vim.log.levels.INFO)
    end
end

--- Clean ALL empty audit sessions across all repositories
function M.clean_all()
    local base_path = storage.get_data_path()
    local removed = storage.clean_all_empty(base_path)

    vim.notify(string.format("Cleaned %d empty audit session(s) globally", removed), vim.log.levels.INFO)
end

return M
