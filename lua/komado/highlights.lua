local M = {}

local NAMED_PREFIX = "Komado_hl_"
local cache = {} -- key (string) -> hl_group name
local counter = 0

local function attrs_to_key(attrs)
  -- Order keys for a stable hash regardless of pairs() order.
  local keys = {}
  for k in pairs(attrs) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. tostring(attrs[k])
  end
  return table.concat(parts, ";")
end

---Resolve a highlight name to its attribute table.
---The returned table is a fresh copy that may be mutated by the caller.
---@param name string
---@return table
function M.get_named_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then
    return {}
  end
  return hl
end

---Ensure a Neovim highlight group exists for the given attribute table and return its name.
---Empty tables produce no group (returns nil).
---@param attrs table?
---@return string? hl_group
function M.ensure_hl_group(attrs)
  if not attrs or next(attrs) == nil then
    return nil
  end

  -- `force` is a komado-specific flag that controls hl inheritance in component._eval, not a real Neovim highlight attribute.
  -- Strip it before keying the cache and calling nvim_set_hl.
  local plain = {}
  for k, v in pairs(attrs) do
    if k ~= "force" then
      plain[k] = v
    end
  end
  if next(plain) == nil then
    return nil
  end

  local key = attrs_to_key(plain)
  local cached = cache[key]
  if cached then
    return cached
  end

  counter = counter + 1
  local name = NAMED_PREFIX .. counter
  vim.api.nvim_set_hl(0, name, plain)
  cache[key] = name
  return name
end

function M.reset()
  cache = {}
  counter = 0
end

return M
