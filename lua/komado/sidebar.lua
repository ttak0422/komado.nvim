local Component = require("komado.component")
local render = require("komado.render")

---@class komado.Sidebar
---@field root komado.Component
---@field _state_id string?  current rendering state id, used by Component:_sidebar_key
---@field _state table?      current state being rendered (winid/bufnr/...)
---@field _updatable table[]
---@field _on_update fun()|nil  invoked by autocmd-driven updates to redraw
local Sidebar = {}
Sidebar.__index = Sidebar

---Build a Sidebar from a normalized spec.
---spec.root is the top-level component tree (any plain table — Line is merely an _kind-tagged table).
---@param spec table
---@return komado.Sidebar
function Sidebar.new(spec)
  local self = setmetatable({}, Sidebar)
  self.spec = spec
  self._updatable = {}
  self._on_update = nil

  local root_spec = spec.root or {}
  self.root = Component:new(root_spec, 1)
  -- Attach this Sidebar reference to every component so events.lua can route update autocmds back here, and so Component:_sidebar_key can use _state_id.
  self.root:broadcast(function(c)
    c._sidebar = self
  end)
  return self
end

---Evaluate the component tree against the given state and produce render output.
---@param state table
---@return string[] lines
---@return table[] extmarks
---@return table line_meta
function Sidebar:eval(state)
  self._state_id = state.id
  self._state = state -- exposed to components (e.g. utils.separator)
  self._updatable = {}
  -- Force a fresh root tree on every render so stale segments do not leak in when condition flips, while keeping _sidebar_cache (per state.id) intact.
  rawset(self.root, "_tree", nil)
  self.root:_eval()
  self.root:freeze_cache()
  local height
  local width
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    height = vim.api.nvim_win_get_height(state.winid)
    width = vim.api.nvim_win_get_width(state.winid)
  end
  return render.collect(self.root, { height = height, width = width })
end

return Sidebar
