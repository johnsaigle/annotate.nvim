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

--- Generate fingerprint for a note based on context
--- Fingerprint is based on: filepath, line content, and 2 lines before/after
--- @param filepath string relative file path
--- @param line_num number line number
--- @return string fingerprint hash
local function generate_fingerprint(filepath, line_num)
    local bufnr = vim.fn.bufnr("%")
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    -- Get context lines (2 before, the line itself, 2 after)
    local start_line = math.max(0, line_num - 3)  -- 0-indexed for nvim_buf_get_lines
    local end_line = math.min(line_count, line_num + 2)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

    -- Build fingerprint string: filepath + surrounding context
    local context = filepath .. ":"
    for _, line_content in ipairs(lines) do
        -- Normalize whitespace
        context = context .. line_content:gsub("%s+", " "):gsub("^%s*", ""):gsub("%s*$", "") .. "|"
    end

    -- Simple hash function (djb2)
    local hash = 5381
    for i = 1, #context do
        hash = ((hash << 5) + hash) + string.byte(context, i)
        hash = hash & 0xFFFFFFFF
    end

    return string.format("%08x", hash)
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

    -- Generate fingerprint
    local fingerprint = generate_fingerprint(session.relative_file, line)

    local note = {
        file = session.relative_file,
        line = line,
        type = note_type,
        text = text,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        commit = session.commit,
        fingerprint = fingerprint
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

--- Extract the first sentence or first line from text
--- @param text string
--- @return string title
local function extract_title(text)
    if not text or text == "" then
        return "Untitled Note"
    end

    -- Find the first sentence (ends with . ! ? followed by space or end of string)
    -- First, try to find a sentence-ending punctuation
    local first_sentence = text:match("^([^%.%!%?]+[%.%!%?])")

    if first_sentence then
        -- Clean up whitespace
        first_sentence = first_sentence:gsub("^%s*", ""):gsub("%s*$", "")
        if #first_sentence > 0 and #first_sentence < #text then
            return first_sentence
        end
    end

    -- If no sentence found or it's the whole text, return the first line
    local first_line = text:match("^([^\n]+)")
    if first_line then
        first_line = first_line:gsub("^%s*", ""):gsub("%s*$", "")
        if #first_line > 60 then
            first_line = first_line:sub(1, 57) .. "..."
        end
        return first_line
    end

    -- Fallback: truncate text
    if #text > 60 then
        return text:sub(1, 57) .. "..."
    end
    return text
end

--- Export a single note at cursor to markdown
--- @param filepath string|nil output path (defaults to ./single-note.md)
function M.export_single(filepath)
    local session = get_current_session()
    if not session then
        return
    end

    -- Get current cursor position
    local parts = vim.fn.getpos(".")
    local line = parts[2]

    -- Load all notes
    local notes_data = storage.load_notes(session.path)
    local metadata = storage.load_metadata(session.path)

    -- Find notes at this line in this file
    local notes_at_line = {}
    for i, note in ipairs(notes_data.notes) do
        if note.file == session.relative_file and note.line == line then
            table.insert(notes_at_line, {index = i, note = note})
        end
    end

    if #notes_at_line == 0 then
        vim.notify("No note found at current line", vim.log.levels.WARN)
        return
    end

    -- If multiple notes, let user choose
    local selected_note
    if #notes_at_line == 1 then
        selected_note = notes_at_line[1].note
    else
        local items = {}
        for _, item in ipairs(notes_at_line) do
            local note = item.note
            local preview = note.text:sub(1, 50)
            if #note.text > 50 then
                preview = preview .. "..."
            end
            table.insert(items, {
                note_index = item.index,
                display = string.format("[%s] %s", note.type:upper(), preview),
                note = note
            })
        end

        vim.ui.select(items, {
            prompt = string.format("Select note to export (%d found):", #notes_at_line),
            format_item = function(item)
                return item.display
            end
        }, function(choice)
            if not choice then
                return
            end
            -- Call export with the selected note
            M._do_export_single(choice.note, session, metadata, filepath)
        end)
        return
    end

    M._do_export_single(selected_note, session, metadata, filepath)
end

--- Internal: Export a single note to markdown
--- Uses the same format as an individual finding in the full report
--- @param note table the note to export
--- @param session AnnotateSession the current session
--- @param metadata table session metadata
--- @param filepath string|nil output path
function M._do_export_single(note, session, metadata, filepath)
    -- Default output path
    local output_path = filepath or "./single-note.md"

    -- Generate markdown using the same per-finding format as export()
    local lines = {}

    -- Generate permalink
    local permalink = generate_permalink(
        session.host, session.owner, session.repo,
        note.commit, note.file, note.line
    )

    -- Extract title from first sentence
    local title = extract_title(note.text)
    table.insert(lines, string.format("### %s", title))
    table.insert(lines, "")

    -- Output full description
    table.insert(lines, note.text)
    table.insert(lines, "")

    -- Output file link in markdown format
    if permalink then
        table.insert(lines, string.format("[%s:%d](%s)", note.file, note.line, permalink))
    else
        table.insert(lines, string.format("`%s:%d`", note.file, note.line))
    end

    table.insert(lines, "")
    table.insert(lines, "---")

    -- Write to file
    local output = table.concat(lines, "\n")
    local file_handle = io.open(output_path, "w")
    if not file_handle then
        vim.notify("Failed to write export file: " .. output_path, vim.log.levels.ERROR)
        return
    end

    file_handle:write(output)
    file_handle:close()

    vim.cmd(string.format('echo "Exported note to %s"', output_path))
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

                -- Extract title from first sentence
                local title = extract_title(note.text)
                table.insert(lines, string.format("### %s", title))
                table.insert(lines, "")

                -- Output full description
                table.insert(lines, note.text)
                table.insert(lines, "")

                -- Output file link in markdown format
                if permalink then
                    table.insert(lines, string.format("[%s:%d](%s)", note.file, note.line, permalink))
                else
                    table.insert(lines, string.format("`%s:%d`", note.file, note.line))
                end

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

--- Get all sessions for the current repository
--- @return table array of {commit, path, notes_data, metadata} objects
local function get_all_repo_sessions()
    local current_file = get_current_name()
    local session = sessions[current_file]

    if not session then
        -- Try to get basic git info without creating a session
        if not git.is_git_repo() then
            vim.notify("Not in a git repository.", vim.log.levels.ERROR)
            return {}
        end

        local repo_root = git.get_repo_root()
        local remote_url = git.get_remote_url()

        if not repo_root or not remote_url then
            vim.notify("Failed to get repository information.", vim.log.levels.ERROR)
            return {}
        end

        local parsed = git.parse_git_url(remote_url)
        if not parsed then
            vim.notify("Failed to parse git remote URL.", vim.log.levels.ERROR)
            return {}
        end

        local base_path = storage.get_data_path()
        local repo_path = string.format("%s/%s/%s/%s", base_path, parsed.host, parsed.owner, parsed.repo)
        local Path = require("plenary.path")
        local path = Path:new(repo_path)

        if not path:exists() then
            return {}
        end

        local all_sessions = {}
        local handle = vim.loop.fs_scandir(repo_path)
        if handle then
            while true do
                local name, type = vim.loop.fs_scandir_next(handle)
                if not name then break end
                if type == "directory" then
                    local session_path = repo_path .. "/" .. name
                    local notes_file = session_path .. "/notes.json"
                    if Path:new(notes_file):exists() then
                        local notes_data = storage.load_notes(session_path)
                        local metadata = storage.load_metadata(session_path)
                        if notes_data and metadata then
                            table.insert(all_sessions, {
                                commit = name,
                                path = session_path,
                                notes_data = notes_data,
                                metadata = metadata
                            })
                        end
                    end
                end
            end
        end

        return all_sessions
    else
        -- Use existing session info
        local base_path = storage.get_data_path()
        local repo_path = string.format("%s/%s/%s/%s", base_path, session.host, session.owner, session.repo)
        local Path = require("plenary.path")
        local path = Path:new(repo_path)

        if not path:exists() then
            return {}
        end

        local all_sessions = {}
        local handle = vim.loop.fs_scandir(repo_path)
        if handle then
            while true do
                local name, type = vim.loop.fs_scandir_next(handle)
                if not name then break end
                if type == "directory" then
                    local session_path = repo_path .. "/" .. name
                    local notes_file = session_path .. "/notes.json"
                    if Path:new(notes_file):exists() then
                        local notes_data = storage.load_notes(session_path)
                        local metadata = storage.load_metadata(session_path)
                        if notes_data and metadata then
                            table.insert(all_sessions, {
                                commit = name,
                                path = session_path,
                                notes_data = notes_data,
                                metadata = metadata
                            })
                        end
                    end
                end
            end
        end

        return all_sessions
    end
end

--- Diff two sessions and find matching/non-matching notes by fingerprint
--- @param session1_commit string commit hash of first session
--- @param session2_commit string commit hash of second session
--- @return table|nil diff result with matching, orphaned1, and orphaned2 arrays
function M.diff_sessions(session1_commit, session2_commit)
    local all_sessions = get_all_repo_sessions()

    if #all_sessions < 2 then
        vim.notify("Need at least 2 audit sessions to diff", vim.log.levels.ERROR)
        return nil
    end

    -- Find the two sessions
    local s1, s2
    for _, s in ipairs(all_sessions) do
        if s.commit == session1_commit then
            s1 = s
        elseif s.commit == session2_commit then
            s2 = s
        end
    end

    if not s1 then
        vim.notify("Session not found: " .. session1_commit, vim.log.levels.ERROR)
        return nil
    end

    if not s2 then
        vim.notify("Session not found: " .. session2_commit, vim.log.levels.ERROR)
        return nil
    end

    -- Build fingerprint maps
    local fingerprints1 = {}
    local fingerprints2 = {}

    for _, note in ipairs(s1.notes_data.notes) do
        if note.fingerprint then
            fingerprints1[note.fingerprint] = fingerprints1[note.fingerprint] or {}
            table.insert(fingerprints1[note.fingerprint], note)
        end
    end

    for _, note in ipairs(s2.notes_data.notes) do
        if note.fingerprint then
            fingerprints2[note.fingerprint] = fingerprints2[note.fingerprint] or {}
            table.insert(fingerprints2[note.fingerprint], note)
        end
    end

    -- Find matches and orphans
    local matching = {}
    local orphaned1 = {}
    local orphaned2 = {}

    -- Find matches and orphaned from session 1
    for fp, notes in pairs(fingerprints1) do
        if fingerprints2[fp] then
            -- Match found
            table.insert(matching, {
                fingerprint = fp,
                notes1 = notes,
                notes2 = fingerprints2[fp]
            })
        else
            -- Orphaned from session 1
            for _, note in ipairs(notes) do
                table.insert(orphaned1, note)
            end
        end
    end

    -- Find orphaned from session 2
    for fp, notes in pairs(fingerprints2) do
        if not fingerprints1[fp] then
            for _, note in ipairs(notes) do
                table.insert(orphaned2, note)
            end
        end
    end

    return {
        session1 = session1_commit,
        session2 = session2_commit,
        matching = matching,
        orphaned1 = orphaned1,
        orphaned2 = orphaned2
    }
end

--- Show diff between current session and another session
function M.show_diff()
    local all_sessions = get_all_repo_sessions()

    if #all_sessions < 2 then
        vim.notify("Need at least 2 audit sessions to diff", vim.log.levels.ERROR)
        return
    end

    -- Get current session commit
    local current_file = get_current_name()
    local current_session = sessions[current_file]
    local current_commit = current_session and current_session.commit or all_sessions[1].commit

    -- Let user select which session to compare with
    local items = {}
    for _, s in ipairs(all_sessions) do
        if s.commit ~= current_commit then
            table.insert(items, {
                commit = s.commit,
                display = string.format("%s (created: %s, notes: %d)",
                    s.commit:sub(1, 7),
                    s.metadata.created_at:sub(1, 10),
                    #s.notes_data.notes)
            })
        end
    end

    if #items == 0 then
        vim.notify("No other sessions to compare with", vim.log.levels.INFO)
        return
    end

    vim.ui.select(items, {
        prompt = "Select session to compare with:",
        format_item = function(item)
            return item.display
        end
    }, function(choice)
        if not choice then
            return
        end

        local diff = M.diff_sessions(current_commit, choice.commit)
        if not diff then
            return
        end

        -- Build display
        local lines = {
            string.format("Diff: %s vs %s", diff.session1:sub(1, 7), diff.session2:sub(1, 7)),
            "",
            string.format("Matching notes (same fingerprint): %d", #diff.matching),
            string.format("Orphaned in %s: %d", diff.session1:sub(1, 7), #diff.orphaned1),
            string.format("Orphaned in %s: %d", diff.session2:sub(1, 7), #diff.orphaned2),
            "",
            "Press 'r' to restore orphaned notes to current session",
            "Press 'h' to harmonize all sessions into current",
            "Press 'q' or <Esc> to close",
            ""
        }

        -- Show orphaned notes from session 2 (can be restored)
        if #diff.orphaned2 > 0 then
            table.insert(lines, "=== Notes that can be restored ===")
            for _, note in ipairs(diff.orphaned2) do
                local preview = note.text:sub(1, 50)
                if #note.text > 50 then
                    preview = preview .. "..."
                end
                table.insert(lines, string.format("[%s] %s:%d - %s",
                    note.type:upper(), note.file, note.line, preview))
            end
        end

        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

        local width = math.min(80, vim.o.columns - 4)
        local height = math.min(#lines + 2, vim.o.lines - 4)

        local win = vim.api.nvim_open_win(buf, true, {
            relative = 'editor',
            width = width,
            height = height,
            row = math.floor((vim.o.lines - height) / 2),
            col = math.floor((vim.o.columns - width) / 2),
            style = 'minimal',
            border = 'rounded',
            title = ' Audit Session Diff ',
            title_pos = 'center'
        })

        -- Set up keymaps
        vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':close<CR>',
            {nowait = true, noremap = true, silent = true})
        vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>',
            {nowait = true, noremap = true, silent = true})
        vim.api.nvim_buf_set_keymap(buf, 'n', 'r', '', {
            nowait = true, noremap = true, silent = true,
            callback = function()
                vim.api.nvim_win_close(win, true)
                M.restore_orphaned(diff.session2, diff.orphaned2)
            end
        })
        vim.api.nvim_buf_set_keymap(buf, 'n', 'h', '', {
            nowait = true, noremap = true, silent = true,
            callback = function()
                vim.api.nvim_win_close(win, true)
                M.harmonize_sessions()
            end
        })
    end)
end

--- Restore orphaned notes from another session to current session
--- @param source_commit string commit hash of source session
--- @param orphaned_notes table array of notes to restore
function M.restore_orphaned(source_commit, orphaned_notes)
    local session = get_current_session(true)
    if not session then
        return
    end

    if not orphaned_notes or #orphaned_notes == 0 then
        vim.notify("No orphaned notes to restore", vim.log.levels.INFO)
        return
    end

    -- Load current notes
    local notes_data = storage.load_notes(session.path)

    -- Add orphaned notes
    local restored_count = 0
    for _, note in ipairs(orphaned_notes) do
        -- Update note with new commit info
        local restored_note = {
            file = note.file,
            line = note.line,
            type = note.type,
            text = note.text,
            created_at = note.created_at,
            commit = session.commit,  -- Update to current commit
            fingerprint = note.fingerprint,
            restored_from = source_commit  -- Track origin
        }
        table.insert(notes_data.notes, restored_note)
        restored_count = restored_count + 1
    end

    -- Sort
    table.sort(notes_data.notes, function(a, b)
        if a.file == b.file then
            return a.line < b.line
        end
        return a.file < b.file
    end)

    -- Save
    storage.save_notes(session.path, notes_data)

    -- Update metadata
    local metadata = storage.load_metadata(session.path)
    metadata.last_modified = os.date("!%Y-%m-%dT%H:%M:%SZ")
    storage.save_metadata(session.path, metadata)

    -- Refresh highlights
    session.highlights = Highlights.AnnotateHighlights:new(
        notes_data.notes, session.relative_file
    )
    session.highlights:refresh_highlights()

    vim.notify(string.format("Restored %d orphaned note(s)", restored_count), vim.log.levels.INFO)
end

--- Harmonize all sessions into current session
--- Combines notes from all sessions, keeping unique fingerprints
function M.harmonize_sessions()
    local session = get_current_session(true)
    if not session then
        return
    end

    local all_sessions = get_all_repo_sessions()
    if #all_sessions <= 1 then
        vim.notify("No other sessions to harmonize", vim.log.levels.INFO)
        return
    end

    -- Load current notes and build fingerprint set
    local notes_data = storage.load_notes(session.path)
    local existing_fingerprints = {}

    for _, note in ipairs(notes_data.notes) do
        if note.fingerprint then
            existing_fingerprints[note.fingerprint] = true
        end
    end

    -- Collect unique notes from other sessions
    local harmonized_count = 0
    for _, s in ipairs(all_sessions) do
        if s.commit ~= session.commit then
            for _, note in ipairs(s.notes_data.notes) do
                if note.fingerprint and not existing_fingerprints[note.fingerprint] then
                    local harmonized_note = {
                        file = note.file,
                        line = note.line,
                        type = note.type,
                        text = note.text,
                        created_at = note.created_at,
                        commit = session.commit,
                        fingerprint = note.fingerprint,
                        harmonized_from = s.commit
                    }
                    table.insert(notes_data.notes, harmonized_note)
                    existing_fingerprints[note.fingerprint] = true
                    harmonized_count = harmonized_count + 1
                end
            end
        end
    end

    if harmonized_count == 0 then
        vim.notify("All notes are already harmonized", vim.log.levels.INFO)
        return
    end

    -- Sort
    table.sort(notes_data.notes, function(a, b)
        if a.file == b.file then
            return a.line < b.line
        end
        return a.file < b.file
    end)

    -- Save
    storage.save_notes(session.path, notes_data)

    -- Update metadata
    local metadata = storage.load_metadata(session.path)
    metadata.last_modified = os.date("!%Y-%m-%dT%H:%M:%SZ")
    metadata.harmonized_from = {}
    for _, s in ipairs(all_sessions) do
        if s.commit ~= session.commit then
            table.insert(metadata.harmonized_from, s.commit)
        end
    end
    storage.save_metadata(session.path, metadata)

    -- Refresh highlights
    session.highlights = Highlights.AnnotateHighlights:new(
        notes_data.notes, session.relative_file
    )
    session.highlights:refresh_highlights()

    vim.notify(string.format("Harmonized %d unique note(s) from %d session(s)",
        harmonized_count, #all_sessions - 1), vim.log.levels.INFO)
end

return M
