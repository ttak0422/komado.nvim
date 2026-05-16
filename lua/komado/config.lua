local M = {}

local default_window = {
  position = "left",
  size = 40,
}

local function check_positive_int(name, v)
  if v == nil then
    return
  end
  if type(v) ~= "number" then
    error(("komado: window.size.%s must be a number (got %s)"):format(name, type(v)))
  end
  if v < 1 then
    error(("komado: window.size.%s must be >= 1 (got %s)"):format(name, tostring(v)))
  end
end

local function check_ratio(v)
  if v == nil then
    return
  end
  if type(v) ~= "number" then
    error(("komado: window.size.ratio must be a number (got %s)"):format(type(v)))
  end
  if v <= 0 or v > 1 then
    error(("komado: window.size.ratio must be in (0, 1] (got %s)"):format(tostring(v)))
  end
end

---Normalize a size value into a uniform table form.
---Accepts:
---```lua
---number                            -- { columns = n }
---{ columns = n }                   -- fixed character width
---{ ratio = r }                     -- fraction of `vim.o.columns`
---{ ratio = r, min = m }            -- ratio clamped above by m
---{ ratio = r, max = m }            -- ratio clamped below by m
---{ ratio = r, min = lo, max = hi } -- clamped both sides
---```
---`columns` and `ratio` are mutually exclusive; supplying both is an error.
---@param size number|table
---@return table { columns?: number, ratio?: number, min?: number, max?: number }
local function normalize_size(size)
  if type(size) == "number" then
    check_positive_int("columns", size)
    return { columns = math.floor(size) }
  end
  if type(size) ~= "table" then
    return { columns = 40 }
  end
  if size.columns ~= nil and size.ratio ~= nil then
    error("komado: window.size accepts either `columns` or `ratio`, not both")
  end
  if size.columns == nil and size.ratio == nil then
    error("komado: window.size requires either `columns` or `ratio`")
  end
  check_positive_int("columns", size.columns)
  check_ratio(size.ratio)
  check_positive_int("min", size.min)
  check_positive_int("max", size.max)
  if size.min and size.max and size.min > size.max then
    error(("komado: window.size.min (%s) must be <= max (%s)"):format(tostring(size.min), tostring(size.max)))
  end
  return {
    columns = size.columns,
    ratio = size.ratio,
    min = size.min,
    max = size.max,
  }
end

---Normalize the user's setup spec, filling in window/buffer defaults and validating constrained fields.
---@param opts? table
---@return table
function M.normalize(opts)
  opts = opts or {}
  local spec = {}
  spec.window = vim.tbl_deep_extend("keep", opts.window or {}, default_window)
  spec.mappings = opts.mappings or {}
  spec.commands = opts.commands or {}
  spec.root = opts.root or {}

  if spec.window.position ~= "left" and spec.window.position ~= "right" then
    error(("komado: window.position must be 'left' or 'right' (got %q)"):format(tostring(spec.window.position)))
  end
  spec.window.size = normalize_size(spec.window.size)
  return spec
end

return M
