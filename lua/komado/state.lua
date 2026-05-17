local M = {}

local current_state -- the singleton sidebar state (shared across tabs)
local current_spec -- the registered sidebar spec
local cursor_memory = {} -- cursor_memory[tabid] = {row, col}
local prior_win = {} -- prior_win[tabid] = winid (last non-sidebar focused window per tab)
local open_flag = false -- "user wants the sidebar to be open"; drives TabEnter auto-reattach

local function get_context(self, row)
  if not row and self.winid and vim.api.nvim_win_is_valid(self.winid) then
    row = vim.api.nvim_win_get_cursor(self.winid)[1]
  end
  if not row then
    return nil
  end
  return self.line_meta[row]
end

---Register the sidebar specification.
---Subsequent calls to `get_or_create()` materialize the singleton state from this spec.
---@param spec table
function M.register(spec)
  current_spec = spec
end

function M.spec()
  return current_spec
end

---Return (creating if needed) the singleton sidebar state.
---@return table state
function M.get_or_create()
  if not current_spec then
    error("komado: sidebar not configured (call komado.setup first)")
  end
  if not current_state then
    current_state = {
      -- Static id; component caches now share a single bucket since the sidebar is no longer per-tab.
      id = "global",
      spec = current_spec,
      bufnr = nil,
      winid = nil,
      line_meta = {},
      commands = vim.tbl_extend("keep", {}, current_spec.commands or {}),
    }
    current_state.get_context = get_context
  end
  return current_state
end

---@return table?
function M.get()
  return current_state
end

function M.dispose()
  current_state = nil
end

---@param flag boolean
function M.set_open(flag)
  open_flag = flag and true or false
end

---@return boolean
function M.is_open()
  return open_flag
end

---Cursor position memory survives close/dispose and TabLeave so re-attaching restores the last viewed line per tab.
function M.save_cursor(tabid, cursor)
  cursor_memory[tabid] = cursor
end

function M.recall_cursor(tabid)
  return cursor_memory[tabid]
end

function M.forget_cursor(tabid)
  cursor_memory[tabid] = nil
end

---Per-tab "user's home window" memo. Used by find_provider_win so each tab's redraw evaluates providers against its own non-sidebar window.
function M.set_prior_win(tabid, winid)
  prior_win[tabid] = winid
end

function M.get_prior_win(tabid)
  return prior_win[tabid]
end

---Drop per-tab memo entries for tabids that are no longer in the given live set. Called from the TabClosed lifecycle hook.
---@param live table<integer, true>
function M.gc_tabs(live)
  for tabid in pairs(prior_win) do
    if not live[tabid] then
      prior_win[tabid] = nil
    end
  end
  for tabid in pairs(cursor_memory) do
    if not live[tabid] then
      cursor_memory[tabid] = nil
    end
  end
end

function M._reset()
  current_state = nil
  current_spec = nil
  cursor_memory = {}
  prior_win = {}
  open_flag = false
end

return M
