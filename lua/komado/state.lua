local M = {}

local store = {} -- store[tabid] = state
local current_spec -- the single registered sidebar spec
local cursor_memory = {} -- cursor_memory[tabid] = {row, col}

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
---Subsequent calls to `get_or_create(tabid)` materialize per-tab state from this spec.
---@param spec table
function M.register(spec)
  current_spec = spec
end

function M.spec()
  return current_spec
end

---@param tabid? integer
---@return table state
function M.get_or_create(tabid)
  tabid = tabid or vim.api.nvim_get_current_tabpage()
  if not current_spec then
    error("komado: sidebar not configured (call komado.setup first)")
  end
  local state = store[tabid]
  if not state then
    state = {
      tabid = tabid,
      id = tostring(tabid),
      spec = current_spec,
      bufnr = nil,
      winid = nil,
      line_meta = {},
      commands = vim.tbl_extend("keep", {}, current_spec.commands or {}),
    }
    state.get_context = get_context
    store[tabid] = state
  end
  return state
end

---@param tabid? integer
---@return table?
function M.get(tabid)
  tabid = tabid or vim.api.nvim_get_current_tabpage()
  return store[tabid]
end

function M.dispose(tabid)
  store[tabid] = nil
end

function M.foreach(fn)
  for tabid, state in pairs(store) do
    fn(tabid, state)
  end
end

---Cursor position memory survives close/dispose, so that re-opening the sidebar restores the user's last viewed line.
function M.save_cursor(tabid, cursor)
  cursor_memory[tabid] = cursor
end

function M.recall_cursor(tabid)
  return cursor_memory[tabid]
end

function M.forget_cursor(tabid)
  cursor_memory[tabid] = nil
end

function M._reset()
  store = {}
  current_spec = nil
  cursor_memory = {}
end

return M
