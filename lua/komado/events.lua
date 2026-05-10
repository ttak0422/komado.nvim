local M = {}

local AUGROUP = "Komado_update_autocmds"

---Register an autocmd that invalidates the per-sidebar cache for `component` and schedules a redraw on the owning sidebar.
---Komado renders into a buffer, so re-rendering only happens when the sidebar is explicitly redrawn — hence the autocmd needs to trigger the redraw itself in addition to clearing the cache.
---@param component table
function M.register_update_autocmd(component)
  -- `clear = false` keeps previously registered autocmds in this group intact across repeat calls and post-teardown recreation.
  vim.api.nvim_create_augroup(AUGROUP, { clear = false })
  local update = component.update
  local events, callback, pattern
  if type(update) == "string" then
    events = update
  else
    events = {}
    for _, e in ipairs(update) do
      events[#events + 1] = e
    end
    callback = update.callback
    pattern = update.pattern
  end

  local id = vim.api.nvim_create_autocmd(events, {
    group = AUGROUP,
    pattern = pattern,
    desc = "Komado update autocmd for " .. vim.inspect(component.id),
    callback = function(args)
      -- Autocmd events are global, so drop the whole per-sidebar cache table to invalidate every state.id at once rather than only the current tab's.
      -- The owning sidebar then redraws each tab that has the sidebar open, and _eval repopulates the cache on next render via set_sidebar_attr.
      component._sidebar_cache = nil
      if callback then
        callback(component, args)
      end
      local sidebar = component._sidebar
      if sidebar and sidebar._on_update then
        sidebar._on_update()
      end
    end,
  })
  -- Record the autocmd (au) id so _eval's "and not self._au_id" guard prevents re-registering the same listener on subsequent evaluations.
  component._au_id = id
end

function M.clear_augroup()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
end

return M
