local M = {}

local NAMED_PREFIX = "Komado_hl_"
local current_scope = "global"
local caches = {} -- scope -> { key (string) -> hl_group name }
local counters = {} -- scope -> integer
local applied_keys = {} -- scope -> { hl_group name -> key (string) }

local function normalize_scope(scope)
  local s = tostring(scope or "global"):gsub("[^%w_]", "_")
  if s == "" then
    return "global"
  end
  return s
end

local function get_scope_cache()
  local cache = caches[current_scope]
  if not cache then
    cache = {}
    caches[current_scope] = cache
  end
  return cache
end

local function next_name()
  local counter = (counters[current_scope] or 0) + 1
  counters[current_scope] = counter
  return NAMED_PREFIX .. current_scope .. "_" .. counter
end

local function get_applied_keys()
  local applied = applied_keys[current_scope]
  if not applied then
    applied = {}
    applied_keys[current_scope] = applied
  end
  return applied
end

local function value_to_key(v)
  if type(v) ~= "table" then
    return tostring(v)
  end

  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. value_to_key(v[k])
  end
  return "{" .. table.concat(parts, ";") .. "}"
end

local function attrs_to_key(attrs)
  -- Order keys for a stable hash regardless of pairs() order.
  local keys = {}
  for k in pairs(attrs) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. value_to_key(attrs[k])
  end
  return table.concat(parts, ";")
end

---Start a render pass for a sidebar instance.
---Generated group names are reused within the scope on each pass, keeping the
---total number of Komado highlight groups bounded by one render's unique attrs.
---@param scope any
function M.begin_render(scope)
  current_scope = normalize_scope(scope)
  caches[current_scope] = {}
  counters[current_scope] = 0
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
  local cache = get_scope_cache()
  local cached = cache[key]
  if cached then
    return cached
  end

  local name = next_name()
  local applied = get_applied_keys()
  if applied[name] ~= key then
    vim.api.nvim_set_hl(0, name, plain)
    applied[name] = key
  end
  cache[key] = name
  return name
end

function M.reset()
  current_scope = "global"
  caches = {}
  counters = {}
  applied_keys = {}
end

return M
