local hl_mod = require("komado.highlights")
local events = require("komado.events")

local tbl_insert = table.insert
local tbl_extend = vim.tbl_extend
local tbl_deep_extend = vim.tbl_deep_extend

local default_restrict = {
  init = true,
  provider = true,
  hl = true,
  condition = true,
  restrict = true,
  pick_child = true,
  after = true,
  mappings = true,
  update = true,
  fallthrough = true,
  vertical_align = true,
  horizontal_align = true,
  horizontal_center = true,
  -- Component variant tag set via DSL (currently only "line" from dsl.Line).
  -- Used by _eval to bracket children with LINE_OPEN/LINE_CLOSE sentinels.
  _kind = true,
  -- Per-sidebar-instance frozen subtree cache used when `update` is set, keyed by state.id via _sidebar_key.
  -- Cleared by the update autocmd.
  _sidebar_cache = true,
  -- Autocmd id returned by nvim_create_autocmd for this component's `update` listener.
  -- Kept so we don't register the same autocmd twice. "au" = autocmd.
  _au_id = true,
}

---Internal sentinels appended to _tree by _eval.
---traverse() in komado.render interprets these.
---LINE_OPEN is a fresh table per Line so it can carry the comp id / self / ctx of the owning Line component.
local LINE_CLOSE = { _komado_close = true }
local LINE_BREAK = { _komado_break = true }
local V_ALIGN = { _komado_v_align = true }
local H_ALIGN = { _komado_h_align = true }

local function is_sentinel(node)
  return type(node) == "table"
    and (node._komado_open or node._komado_close or node._komado_break or node._komado_v_align or node._komado_h_align)
end

local function is_segment(node)
  return type(node) == "table" and node.text ~= nil
end

local function copy_tree(src, dst)
  for _, node in ipairs(src) do
    -- Recurse only into nested arrays (a child component's _tree).
    -- Sentinels, segments, and primitive values are copied by reference.
    if type(node) == "table" and not is_sentinel(node) and not is_segment(node) then
      local sub = {}
      copy_tree(node, sub)
      dst[#dst + 1] = sub
    else
      dst[#dst + 1] = node
    end
  end
end

---Shallow-copy table user-values so that downstream mutations do not leak back to the spec.
---Pass-through for nil / function / string (no shared mutation risk).
local function copy_user_value(v)
  if type(v) == "table" then
    return tbl_extend("keep", v, {})
  end
  return v
end

---Merge a parent's resolved hl into the current component's hl.
---If parent has `force = true`, parent wins on key collisions; otherwise child wins (the default for hl inheritance).
local function merge_hl(parent_hl, self_hl)
  self_hl = self_hl and tbl_extend("force", {}, self_hl) or {}
  if not parent_hl then
    return self_hl
  end
  parent_hl = tbl_extend("force", {}, parent_hl)
  return tbl_extend(parent_hl.force and "keep" or "force", parent_hl, self_hl)
end

local function push_provider(tree, value, hl_attrs, comp_id, self_ref, ctx, mappings)
  if value == nil or value == "" then
    return
  end
  if type(value) == "table" then
    for i, s in ipairs(value) do
      if i > 1 then
        tbl_insert(tree, LINE_BREAK)
      end
      if s ~= nil and s ~= "" then
        tbl_insert(tree, {
          text = tostring(s),
          hl = hl_attrs,
          comp = comp_id,
          self_ref = self_ref,
          ctx = ctx,
          mappings = mappings,
        })
      end
    end
  else
    tbl_insert(tree, {
      text = tostring(value),
      hl = hl_attrs,
      comp = comp_id,
      self_ref = self_ref,
      ctx = ctx,
      mappings = mappings,
    })
  end
end

---@class komado.Component
---@field id integer[]
---@field _tree table
---@field _sidebar table?  parent sidebar reference (set via broadcast after construction)
---@field hl? string|table|fun(self):(string|table)
---@field update? string|string[]|table|fun(self):boolean
---@field condition? fun(self):boolean
---@field pick_child? integer[]
---@field fallthrough? boolean
---@field init? fun(self)
---@field provider? string|string[]|fun(self):(string|string[])
---@field after? fun(self)
---@field mappings? table row-local key handlers
---@field vertical_align? boolean  vertical alignment marker resolved by render.collect
---@field horizontal_align? boolean  horizontal alignment marker resolved within the current line
---@field horizontal_center? boolean  center the rendered Line content within the sidebar width
---@field restrict? table<string, true>
---@field _kind? "line"  component variant tag (see default_restrict)
---@field _sidebar_cache? table<string, table>  per state.id frozen subtree cache
---@field _au_id? integer  autocmd id from nvim_create_autocmd
local Component = {}

function Component.sentinels()
  return { LINE_CLOSE = LINE_CLOSE, LINE_BREAK = LINE_BREAK, V_ALIGN = V_ALIGN, H_ALIGN = H_ALIGN }
end

---@param child table
---@param index? integer
---@return komado.Component
function Component:new(child, index)
  child = child or {}
  local new = {}

  new.hl = copy_user_value(child.hl)
  new.update = copy_user_value(child.update)

  new.condition = child.condition
  new.pick_child = child.pick_child and tbl_extend("keep", child.pick_child, {}) or nil
  if child.fallthrough ~= nil then
    new.fallthrough = child.fallthrough
  else
    new.fallthrough = true
  end
  new.init = child.init
  new.provider = child.provider
  new.after = child.after
  new.mappings = copy_user_value(child.mappings)
  new.vertical_align = child.vertical_align
  new.horizontal_align = child.horizontal_align
  new.horizontal_center = child.horizontal_center
  new.restrict = child.restrict and tbl_extend("keep", child.restrict, {}) or nil
  new._kind = child._kind

  if child.static then
    for k, v in pairs(tbl_deep_extend("keep", child.static, {})) do
      new[k] = v
    end
  end

  local restrict = tbl_extend("force", default_restrict, self.restrict or {})
  setmetatable(new, self)
  self.__index = function(_, v)
    if not restrict[v] then
      return self[v]
    end
  end

  local parent_id = self.id or {}
  new.id = tbl_extend("force", parent_id, { [#parent_id + 1] = index })

  for i, sub in ipairs(child) do
    new[i] = new:new(sub, i)
  end

  return new
end

function Component:broadcast(func)
  func(self)
  for _, c in ipairs(self) do
    c:broadcast(func)
  end
end

function Component:find(pred)
  if pred(self) then
    return self
  end
  for _, c in ipairs(self) do
    local r = c:find(pred)
    if r then
      return r
    end
  end
end

function Component:get(id)
  id = id or {}
  local cur = self
  for _, i in ipairs(id) do
    cur = cur[i]
  end
  return cur
end

function Component:is_child(other)
  if not other then
    return false
  end
  if #self.id <= #other.id then
    return false
  end
  for i, v in ipairs(other.id) do
    if self.id[i] ~= v then
      return false
    end
  end
  return true
end

function Component:nonlocal(attr)
  return getmetatable(self).__index(self, attr)
end

function Component:local_(attr)
  return rawget(self, attr)
end

---Per-(sidebar instance) attribute storage.
---The key is the sidebar-instance id (state.id, typically the tabid).
---Used to keep update caches isolated between tabs.
---Falls back to "_global" when no sidebar is attached.
function Component:_sidebar_key()
  local sb = self._sidebar
  if sb and sb._state_id then
    return sb._state_id
  end
  return "_global"
end

function Component:set_sidebar_attr(attr, val)
  local key = self:_sidebar_key()
  self[attr] = self[attr] or {}
  self[attr][key] = val
end

function Component:get_sidebar_attr(attr)
  if not self[attr] then
    return nil
  end
  return self[attr][self:_sidebar_key()]
end

function Component:clear_tree()
  local tree = rawget(self, "_tree")
  if not tree then
    return
  end
  for i = 1, #tree do
    tree[i] = nil
  end
end

---@return boolean
function Component:_eval()
  if not self:local_("_tree") then
    self._tree = {}
  else
    self:clear_tree()
  end

  local tree = self._tree

  -- Register the autocmd-driven `update` BEFORE the condition gate.
  -- Otherwise a component that starts out hidden (condition=false) would never get its listener attached and could not re-emerge when its own event fires.
  -- Function-form `update` has no side effect and is cheap to skip until the component is actually visible, so we defer it past the condition.
  local update = self.update
  if update and type(update) ~= "function" and not self._au_id then
    events.register_update_autocmd(self)
  end

  if self.condition and not self:condition() then
    return false
  end

  if update then
    if type(update) == "function" then
      if update(self) then
        self:set_sidebar_attr("_sidebar_cache", nil)
      end
    end

    local cache = self:get_sidebar_attr("_sidebar_cache")
    if cache then
      copy_tree(cache, tree)
      return true
    end
  end

  if self.init then
    self:init()
  end

  local hl = self.hl or {}
  hl = type(hl) == "function" and (hl(self) or {}) or hl
  if type(hl) == "string" then
    hl = hl_mod.get_named_hl(hl)
  end

  self.merged_hl = merge_hl(self:nonlocal("merged_hl"), hl)

  if self.vertical_align then
    tbl_insert(tree, V_ALIGN)
  elseif self.horizontal_align then
    tbl_insert(tree, H_ALIGN)
  else
    if self._kind == "line" then
      tbl_insert(tree, {
        _komado_open = true,
        comp = self.id,
        self_ref = self,
        ctx = rawget(self, "_ctx"),
        mappings = self.mappings,
        horizontal_center = self.horizontal_center,
      })
    end

    local provider = self.provider
    if provider then
      local v = type(provider) == "function" and provider(self) or provider
      push_provider(
        tree,
        v,
        self.merged_hl,
        self.id,
        self,
        rawget(self, "_ctx") or self:nonlocal("_ctx"),
        self.mappings
      )
    end

    local pick_child = self.pick_child
    local picked
    if pick_child then
      picked = {}
      for _, i in ipairs(pick_child) do
        tbl_insert(picked, self[i])
      end
    end

    for _, child in ipairs(picked or self) do
      child._tree = {}
      tbl_insert(tree, child._tree)
      local ok = child:_eval()
      if not ok then
        table.remove(tree)
      end
      if ok and not self.fallthrough then
        break
      end
    end

    if self._kind == "line" then
      tbl_insert(tree, LINE_CLOSE)
    end
  end

  if self.after then
    self:after()
  end

  if update and self._sidebar then
    self._sidebar._updatable[#self._sidebar._updatable + 1] = self
  end

  return true
end

---After top-level _eval, freeze the rendered subtree for components that opted in with `update`.
---Subsequent renders reuse the frozen subtree until the autocmd fires and clears the cache (see events.register_update_autocmd).
function Component:freeze_cache()
  if not self._sidebar then
    return
  end
  for _, c in ipairs(self._sidebar._updatable) do
    local frozen = {}
    copy_tree(c._tree, frozen)
    c:set_sidebar_attr("_sidebar_cache", frozen)
  end
end

return Component
