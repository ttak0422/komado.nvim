local hl_mod = require("komado.highlights")
local dsl = require("komado.dsl")

local M = {}

---Sidebar content helper.
---Returns the current render width (in cells) after global padding is removed, or 0 if no window is attached.
---@param self table component instance
---@return integer
local function content_width(self)
  local sb = self._sidebar
  local st = sb and sb._state
  if not st then
    return 0
  end
  return st._content_width or 0
end

---Full-width horizontal rule that follows the padded sidebar content width.
---Lifecycle resize redraws keep it flush after `:vert resize`.
---@param char? string repeated character (default "─")
---@param hl? string|table highlight name or attribute table
---@return table line component
function M.separator(char, hl)
  char = char or "─"
  return dsl.Line({
    hl = hl,
    provider = function(self)
      local w = content_width(self)
      if w <= 0 then
        return ""
      end
      return string.rep(char, w)
    end,
  })
end

---Vertical alignment marker, equivalent in spirit to statusline's `%=`.
---At render time it expands to blank rows so following components are pushed toward the bottom of the sidebar.
---@return table component
function M.vertical_align()
  return {
    vertical_align = true,
  }
end

---Horizontal alignment marker, equivalent in spirit to statusline's `%=`.
---Use inside a Line; at render time it expands to spaces so following segments are pushed right.
---@return table component
function M.horizontal_align()
  return {
    horizontal_align = true,
  }
end

---Center one or more components on a single line.
---Unlike `horizontal_align()`, this centers the whole rendered line content within the sidebar width.
---@vararg table component specs
---@return table line component
function M.center(...)
  local children = { ... }
  if #children == 1 and type(children[1]) == "table" and children[1]._kind == "line" then
    return M.clone(children[1], { horizontal_center = true })
  end
  local line = { horizontal_center = true }
  for i, child in ipairs(children) do
    line[i] = child
  end
  return dsl.Line(line)
end

---Deep-merge `with` into a copy of `block` and return the result.
---Useful for specializing a shared component spec without mutating the original.
---@generic T: table
---@param block T
---@param with? table
---@return T
function M.clone(block, with)
  return vim.tbl_deep_extend("force", vim.deepcopy(block), with or {})
end

---Append component specs as children of `destination`, returning a new spec.
---@param destination table
---@vararg table
---@return table
function M.insert(destination, ...)
  local out = vim.deepcopy(destination)
  for _, child in ipairs({ ... }) do
    out[#out + 1] = child
  end
  return out
end

---Repeat `str` (default " ") `level` times to build an indent string.
---@param level integer
---@param str? string
---@return string
function M.make_indent(level, str)
  return string.rep(str or " ", math.max(0, level or 0))
end

---Wrap a component with left/right delimiters whose color follows `color`.
---@param delimiters string[2]
---@param color string|fun(self: table): string|nil
---@param component table
---@return table
function M.surround(delimiters, color, component)
  if type(component) ~= "table" then
    error("komado.utils.surround: component must be a table")
  end
  local function compute_color(self)
    if type(color) == "function" then
      return color(self)
    end
    return color
  end

  local function side_hl(self)
    local c = compute_color(self)
    return c and { fg = c } or {}
  end

  local user_hl = component.hl
  local body_spec = M.clone(component, {
    hl = function(self)
      local h = user_hl
      if type(h) == "function" then
        h = h(self)
      end
      if type(h) == "string" then
        h = hl_mod.get_named_hl(h)
      end
      local merged = vim.tbl_extend("keep", {}, h or {})
      local c = compute_color(self)
      if c then
        merged.bg = c
      end
      return merged
    end,
  })

  return {
    { provider = delimiters[1], hl = side_hl },
    body_spec,
    { provider = delimiters[2], hl = side_hl },
  }
end

---Map an array of items into per-row child components.
---The list is rebuilt each evaluation; render_item should return a component spec (typically a Line).
---Each generated child has `self._ctx = { item = item, index = i }` set so that keymap handlers can read the underlying item via `state:get_context()`.
---@param get_items fun(self: table): any[]
---@param render_item fun(item: any, i: integer, self: table): table
---@return table
function M.mapped_list(get_items, render_item)
  return {
    init = function(self)
      local items = get_items(self) or {}
      for i, item in ipairs(items) do
        local spec = render_item(item, i, self)
        spec = vim.deepcopy(spec)
        local user_init = spec.init
        spec.init = function(child)
          child._ctx = { item = item, index = i }
          if user_init then
            user_init(child)
          end
        end
        self[i] = self:new(spec, i)
      end
      for i = #items + 1, #self do
        self[i] = nil
      end
    end,
  }
end

return M
