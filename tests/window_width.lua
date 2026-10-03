-- Run from the repository root: nvim --headless -u NONE -i NONE -l tests/window_width.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 180
vim.o.lines = 40
vim.o.equalalways = true

local komado = require("komado")
local api = vim.api
local cases = 0

local function equal(actual, expected, message)
  assert(actual == expected, ("%s: expected %s, got %s"):format(message, tostring(expected), tostring(actual)))
end

local function equalize()
  vim.cmd("normal! " .. api.nvim_replace_termcodes("<C-W>=", true, false, true))
end

local function verify_layout(state, editors, width)
  -- Check actual Ctrl-W= from both the sidebar and an ordinary window.
  for _, winid in ipairs({ state.winid, editors[1] }) do
    api.nvim_set_current_win(winid)
    equalize()
    equal(api.nvim_win_get_width(state.winid), width, "sidebar width after Ctrl-W=")
    local a = api.nvim_win_get_width(editors[1])
    local b = api.nvim_win_get_width(editors[2])
    assert(math.abs(a - b) <= 1, "ordinary windows must equalize")
  end
  for _, winid in ipairs(editors) do
    equal(vim.wo[winid].winfixwidth, false, "ordinary window options are unchanged")
  end
  equal(vim.wo[state.winid].winfixwidth, true, "sidebar has winfixwidth")
end

local function editor_pair()
  local first = api.nvim_get_current_win()
  vim.cmd("vsplit")
  return { first, api.nvim_get_current_win() }
end

local function run()
  for _, position in ipairs({ "left", "right" }) do
    for _, size in ipairs({ 28, { ratio = 0.2, min = 20, max = 45 } }) do
      komado.close()
      vim.cmd("tabonly!")
      vim.cmd("only!")
      local editors = editor_pair()
      komado.setup({ window = { position = position, size = size } })
      local state = komado.open()
      local configured = require("komado.window").resolve_width(state.spec.window.size)
      verify_layout(state, editors, configured)

      api.nvim_set_current_win(state.winid)
      vim.cmd("vertical resize 37")
      equal(api.nvim_win_get_width(state.winid), 37, "explicit resize works")
      -- Process the same redraw callback as interactive resizing; it must not refit.
      api.nvim_exec_autocmds("WinResized", { modeline = false })
      vim.wait(20, function()
        return false
      end)
      verify_layout(state, editors, 37)
      api.nvim_set_current_win(state.winid)
      vim.cmd("normal! " .. api.nvim_replace_termcodes("3<C-W>>", true, false, true))
      verify_layout(state, editors, 40)

      -- Editor resize still applies the configured size, including ratio sizing.
      api.nvim_exec_autocmds("VimResized", { modeline = false })
      verify_layout(state, editors, configured)

      -- An externally closed window is also recreated through the same path.
      api.nvim_win_close(state.winid, true)
      state = komado.open()
      verify_layout(state, editors, configured)

      komado.close({ keep_buffer = true })
      state = komado.open()
      verify_layout(state, editors, configured)
      komado.close()
      state = komado.open()
      verify_layout(state, editors, configured)

      local original_tab = api.nvim_get_current_tabpage()
      api.nvim_set_current_win(editors[1])
      vim.cmd("tabnew")
      -- TabEnter attaches the singleton to the new tab, with a new window.
      state = komado.get_state()
      local other_editors = editor_pair()
      verify_layout(state, other_editors, configured)
      api.nvim_set_current_tabpage(original_tab)
      state = komado.get_state()
      verify_layout(state, editors, configured)

      -- Repeated setup must recreate the option with the new configuration.
      komado.setup({ window = { position = position, size = 32 } })
      state = komado.open()
      verify_layout(state, editors, 32)
      cases = cases + 1
    end
  end
  komado.close()
  print(("PASS: %d sidebar width/lifecycle scenarios"):format(cases))
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
