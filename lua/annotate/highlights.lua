local M = {}

---@class AnnotateNote
---@field file string relative path from repo root
---@field line number line number
---@field type string "finding"|"question"|"safe"|"suggestion"|"comment"|"invariant"
---@field text string note content
---@field created_at string ISO8601 timestamp
---@field commit string commit hash when note was created

---@class AnnotateHighlights
---@field notes AnnotateNote[] all notes for current file
---@field win_id number|nil popup window id
---@field buf_id number|nil popup buffer id
local AnnotateHighlights = {}
AnnotateHighlights.__index = AnnotateHighlights

--- Create new highlights manager for current file
--- @param all_notes AnnotateNote[] all notes in session
--- @param current_file string relative path of current file
--- @return AnnotateHighlights
function AnnotateHighlights:new(all_notes, current_file)
    -- Filter notes to only those for current file
    local file_notes = {}
    for _, note in ipairs(all_notes) do
        if note.file == current_file then
            table.insert(file_notes, note)
        end
    end
    
    return setmetatable({
        notes = file_notes,
        win_id = nil,
        buf_id = nil,
    }, self)
end

--- Get notes at cursor position
--- @return AnnotateNote[]
function AnnotateHighlights:get_from_cursor()
    local parts = vim.fn.getpos(".")
    local line = parts[2]
    
    local result = {}
    for _, note in ipairs(self.notes) do
        if note.line == line then
            table.insert(result, note)
        end
    end
    
    return result
end

--- Navigate to next note
function AnnotateHighlights:nav_next()
    if #self.notes == 0 then
        return
    end
    
    local parts = vim.fn.getpos(".")
    local line = parts[2]
    
    ---@type AnnotateNote
    local nearest = self.notes[1]
    
    for i = 2, #self.notes do
        local note = self.notes[i]
        local diff = note.line - line
        local nearest_diff = nearest.line - line
        if diff > 0 and nearest_diff <= 0 then
            nearest = note
        end
    end
    
    vim.api.nvim_win_set_cursor(0, {nearest.line, 0})
    vim.api.nvim_feedkeys("_", "m", true)
end

--- Show notes at cursor in popup window
function AnnotateHighlights:show_notes()
    self:close_notes()
    
    if #self.notes == 0 then
        return
    end
    
    local parts = vim.fn.getpos(".")
    local line = parts[2]
    
    local cursor_notes = {}
    for _, note in ipairs(self.notes) do
        if note.line == line then
            table.insert(cursor_notes, note)
        end
    end
    
    if #cursor_notes == 0 then
        return
    end
    
    local lines = {}
    local requires_headers = #cursor_notes > 1
    
    for i, note in ipairs(cursor_notes) do
        if requires_headers then
            table.insert(lines, string.format("Note %d [%s]", i, note.type:upper()))
        else
            table.insert(lines, string.format("[%s]", note.type:upper()))
        end
        table.insert(lines, note.text)
        table.insert(lines, "")
    end
    
    local buf_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
    local win_id = vim.api.nvim_open_win(buf_id, false, {
        relative = "cursor",
        width = 50,
        height = math.min(#lines + 2, 10),
        row = 0,
        col = 0,
        style = "minimal",
        border = "rounded"
    })
    
    self.buf_id = buf_id
    self.win_id = win_id
end

--- Close popup window
function AnnotateHighlights:close_notes()
    if self.win_id ~= nil and vim.api.nvim_win_is_valid(self.win_id) then
        vim.api.nvim_win_close(self.win_id, true)
    end
    
    if self.buf_id and vim.api.nvim_buf_is_valid(self.buf_id) then
        vim.api.nvim_buf_delete(self.buf_id, {force = true})
    end
    
    self.win_id = nil
    self.buf_id = nil
end

--- Refresh sign display in gutter
function AnnotateHighlights:refresh_highlights()
    local ok = pcall(vim.fn.sign_unplace, "AnnotateGroup", {buffer = vim.fn.bufnr("%")})
    if not ok then
        vim.notify("Failed to clear signs. Make sure annotate is set up.", vim.log.levels.ERROR)
        return
    end
    
    for _, note in ipairs(self.notes) do
        -- Map type to sign name
        local sign_name = "Annotate" .. note.type:sub(1,1):upper() .. note.type:sub(2)
        
        ok = pcall(vim.fn.sign_place, 0, "AnnotateGroup", sign_name, 
                   vim.fn.bufnr("%"), {lnum = note.line})
        if not ok then
            vim.notify("Failed to place sign. Make sure annotate is set up.", vim.log.levels.ERROR)
        end
    end
end

return {
    AnnotateHighlights = AnnotateHighlights,
}
