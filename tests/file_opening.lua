-- Run from the repository root: nvim --headless -u NONE -i NONE -l tests/file_opening.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 180
vim.o.lines = 50
local api = vim.api
local komado = require("komado")
local state_m = require("komado.state")
local cases = 0
local files = {}
local jobs = {}

local function equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect({ actual = actual, expected = expected }))
end

local function settle()
  vim.wait(30, function()
    return false
  end)
end

local function file()
  local path = vim.fn.tempname()
  files[#files + 1] = path
  vim.fn.writefile(
    vim.fn.map(vim.fn.range(1, 50), function(_, n)
      return "line " .. n
    end),
    path
  )
  return path
end

local function fixture(position)
  komado.close()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  local editor = api.nvim_get_current_win()
  komado.setup({
    window = { position = position or "left", size = 30 },
    root = { require("komado.dsl").Line({ provider = "sidebar", update = "BufEnter" }) },
  })
  local state = komado.open({ focus = true })
  return state, editor
end

local function restored(state)
  settle()
  equal(api.nvim_win_get_buf(state.winid), state.bufnr, "owned window keeps its sidebar buffer")
  equal(api.nvim_buf_get_lines(state.bufnr, 0, -1, false), { "sidebar" }, "sidebar content survives")
end

local function opened(state, editor, buf, cursor)
  restored(state)
  equal(api.nvim_win_get_buf(editor), buf, "file is shown in editor")
  equal(api.nvim_get_current_win(), editor, "foreground open focuses editor")
  if cursor then
    equal(api.nvim_win_get_cursor(editor), cursor, "opener cursor is preserved")
  end
end

local function test(name, fn)
  fn()
  cases = cases + 1
  print("PASS: " .. name)
end

local function run()
  for _, position in ipairs({ "left", "right" }) do
    test(position .. " :edit, repeated opens and buffer switches", function()
      local st, editor = fixture(position)
      local path = file()
      vim.cmd("edit +17 " .. vim.fn.fnameescape(path))
      local buf = api.nvim_get_current_buf()
      opened(st, editor, buf, { 17, 0 })
      equal(vim.wo[editor].winfixwidth, false, "editor does not inherit sidebar options")
      for _ = 1, 2 do
        api.nvim_set_current_win(st.winid)
        vim.cmd("buffer " .. buf)
        opened(st, editor, buf)
      end
      api.nvim_set_current_win(st.winid)
      vim.cmd("bnext")
      opened(st, editor, buf)
      api.nvim_set_current_win(st.winid)
      vim.cmd("edit " .. vim.fn.fnameescape(path .. "-new"))
      opened(st, editor, api.nvim_get_current_buf())
      equal(#api.nvim_tabpage_list_wins(0), 2, "repeated opening does not add splits")
    end)
  end

  test("LSP show_document retains its explicit window cursor update", function()
    local st, editor = fixture()
    local path = file()
    assert(vim.lsp.util.show_document({
      uri = vim.uri_from_fname(path),
      range = { start = { line = 22, character = 3 }, ["end"] = { line = 22, character = 3 } },
    }, "utf-16", { focus = true }))
    opened(st, editor, vim.fn.bufnr(path), { 23, 3 })
  end)

  test("background API replacement and redraw preserve editor focus", function()
    local st, editor = fixture()
    api.nvim_set_current_win(editor)
    local buf = vim.fn.bufadd(file())
    vim.fn.bufload(buf)
    api.nvim_win_set_buf(st.winid, buf)
    api.nvim_win_set_cursor(st.winid, { 12, 2 })
    restored(st)
    equal(api.nvim_get_current_win(), editor, "background event does not steal focus")
    equal(api.nvim_win_get_cursor(editor), { 12, 2 }, "background view is transferred")
    api.nvim_set_current_win(st.winid)
    komado.redraw()
    settle()
    equal(api.nvim_get_current_win(), st.winid, "ordinary sidebar updates keep sidebar focus")
  end)

  test("closed prior window falls back to another editor", function()
    local st, editor = fixture()
    api.nvim_set_current_win(editor)
    vim.cmd("split")
    local other = api.nvim_get_current_win()
    state_m.set_prior_win(api.nvim_get_current_tabpage(), editor)
    api.nvim_win_close(editor, true)
    api.nvim_set_current_win(st.winid)
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    opened(st, other, api.nvim_get_current_buf())
  end)

  for _, position in ipairs({ "left", "right" }) do
    test(position .. " sidebar alone creates an editing split", function()
      local st, editor = fixture(position)
      api.nvim_win_close(editor, true)
      vim.cmd("edit " .. vim.fn.fnameescape(file()))
      local buf = api.nvim_get_current_buf()
      restored(st)
      local target = api.nvim_get_current_win()
      assert(target ~= st.winid, "new editor receives focus")
      equal(api.nvim_win_get_buf(target), buf, "new split displays file")
      equal(vim.wo[target].winfixwidth, false, "new editor has ordinary options")
      equal(api.nvim_win_get_width(st.winid), 30, "sidebar width survives split")
    end)
  end

  test("terminal, float, other panels and fixed buffers are not destinations", function()
    local st, editor = fixture()
    api.nvim_set_current_win(editor)
    vim.cmd("enew")
    local term = api.nvim_get_current_buf()
    local job = vim.fn.termopen({ "cat" })
    jobs[#jobs + 1] = job
    vim.cmd("vnew")
    local panel = api.nvim_get_current_win()
    local panel_buf = api.nvim_get_current_buf()
    vim.bo[panel_buf].buftype = "nofile"
    vim.bo[panel_buf].filetype = "komado"
    vim.cmd("vnew")
    local fixed = api.nvim_get_current_win()
    vim.wo[fixed].winfixbuf = true
    local fixed_buf = api.nvim_get_current_buf()
    local float_buf = api.nvim_create_buf(false, true)
    local float = api.nvim_open_win(float_buf, false, { relative = "editor", row = 1, col = 1, width = 10, height = 3 })
    state_m.set_prior_win(api.nvim_get_current_tabpage(), editor)
    api.nvim_set_current_win(st.winid)
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    local buf = api.nvim_get_current_buf()
    restored(st)
    local target = api.nvim_get_current_win()
    assert(target ~= editor and target ~= panel and target ~= fixed and target ~= float, "new safe destination")
    equal(api.nvim_win_get_buf(target), buf, "file is visible")
    equal(api.nvim_win_get_buf(editor), term, "terminal buffer stays displayed")
    equal(vim.fn.jobwait({ job }, 0)[1], -1, "terminal process stays alive")
    equal(api.nvim_win_get_buf(panel), panel_buf, "other panel is untouched")
    equal(api.nvim_win_get_buf(fixed), fixed_buf, "fixed buffer is untouched")
    equal(api.nvim_win_get_buf(float), float_buf, "float is untouched")
    api.nvim_win_close(float, true)
  end)

  test("duplicate sidebar buffers are not used as editors", function()
    local st, editor = fixture()
    vim.cmd("vsplit")
    local duplicate = api.nvim_get_current_win()
    api.nvim_win_close(editor, true)
    api.nvim_set_current_win(st.winid)
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    local buf = api.nvim_get_current_buf()
    restored(st)
    equal(api.nvim_win_get_buf(duplicate), st.bufnr, "unowned duplicate is untouched")
    equal(api.nvim_get_current_buf(), buf, "file has a new editor")
  end)

  test("background replacement does not focus a different editor", function()
    local st, editor = fixture()
    api.nvim_set_current_win(editor)
    vim.cmd("vnew")
    local focused = api.nvim_get_current_win()
    local focused_buf = api.nvim_get_current_buf()
    state_m.set_prior_win(api.nvim_get_current_tabpage(), editor)
    api.nvim_win_set_buf(st.winid, vim.fn.bufadd(file()))
    restored(st)
    equal(api.nvim_get_current_win(), focused, "background operation preserves actual focus")
    equal(api.nvim_win_get_buf(focused), focused_buf, "focused editor buffer is untouched")
  end)

  test("modified editor and wipe-on-hide incoming buffer survive", function()
    local st, editor = fixture()
    api.nvim_buf_set_lines(api.nvim_win_get_buf(editor), 0, -1, false, { "unsaved" })
    local unsaved = api.nvim_win_get_buf(editor)
    vim.o.hidden = false
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    api.nvim_win_set_buf(st.winid, buf)
    restored(st)
    equal(api.nvim_get_current_buf(), buf, "wipe-on-hide buffer remains visible in a new editor")
    equal(api.nvim_win_get_buf(editor), unsaved, "modified editor remains visible")
    equal(api.nvim_buf_get_lines(unsaved, 0, -1, false), { "unsaved" }, "unsaved content is retained")
    equal(vim.bo[unsaved].modified, true, "unsaved buffer remains modified")
    vim.o.hidden = true
  end)

  test("reopening a displayed modified file reuses its editor", function()
    local st, editor = fixture()
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    local buf = api.nvim_get_current_buf()
    opened(st, editor, buf)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved" })
    api.nvim_set_current_win(st.winid)
    vim.cmd("buffer " .. buf)
    opened(st, editor, buf)
    equal(#api.nvim_tabpage_list_wins(0), 2, "modified file does not accumulate splits")
  end)

  test("background fallback split preserves floating-window focus", function()
    local st, editor = fixture()
    vim.bo[api.nvim_win_get_buf(editor)].buftype = "nofile"
    local float_buf = api.nvim_create_buf(false, true)
    local float = api.nvim_open_win(float_buf, true, { relative = "editor", row = 1, col = 1, width = 10, height = 3 })
    api.nvim_win_set_buf(st.winid, vim.fn.bufadd(file()))
    restored(st)
    equal(api.nvim_get_current_win(), float, "creating a split in background does not steal focus")
    equal(#api.nvim_tabpage_list_wins(0), 4, "safe editing split was created")
    api.nvim_win_close(float, true)
  end)

  test("closing before the queued restore keeps the opened file", function()
    local st, editor = fixture()
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    local buf = api.nvim_get_current_buf()
    komado.close()
    settle()
    equal(api.nvim_win_is_valid(st.winid or -1), false, "sidebar is closed")
    equal(api.nvim_win_get_buf(editor), buf, "close preserves opened file")
  end)

  test("tab switch before restore keeps file in its original tab", function()
    local st, editor = fixture()
    local tab = api.nvim_get_current_tabpage()
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    local buf = api.nvim_get_current_buf()
    vim.cmd("tabnew")
    local other_tab = api.nvim_get_current_tabpage()
    local other_editor = api.nvim_get_current_win()
    restored(st)
    equal(api.nvim_get_current_tabpage(), other_tab, "restore does not switch tabs")
    equal(api.nvim_get_current_win(), other_editor, "new tab focus is retained")
    equal(api.nvim_win_get_buf(editor), buf, "original tab has the opened file")
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    local other_buf = api.nvim_get_current_buf()
    settle()
    api.nvim_set_current_tabpage(tab)
    state_m.set_prior_win(tab, other_editor)
    api.nvim_set_current_win(st.winid)
    vim.cmd("buffer " .. buf)
    opened(st, editor, buf)
    equal(api.nvim_win_get_buf(other_editor), other_buf, "other tab is untouched")
  end)

  test("sidebar cursor survives close and tab switch before queued restore", function()
    fixture()
    local root = {}
    for n = 1, 40 do
      root[#root + 1] = require("komado.dsl").Line({ provider = "panel " .. n })
    end
    komado.setup({ root = root })
    local st = komado.open({ focus = true })
    api.nvim_win_set_cursor(st.winid, { 20, 2 })
    vim.cmd("edit +33 " .. vim.fn.fnameescape(file()))
    komado.close({ keep_buffer = true })
    st = komado.open({ focus = true })
    equal(api.nvim_win_get_cursor(st.winid), { 20, 2 }, "close remembers sidebar cursor")
    local tab = api.nvim_get_current_tabpage()
    vim.cmd("edit +33 " .. vim.fn.fnameescape(file()))
    vim.cmd("tabnew")
    settle()
    api.nvim_set_current_tabpage(tab)
    equal(api.nvim_win_get_cursor(st.winid), { 20, 2 }, "tab switch remembers sidebar cursor")
  end)

  test("external close, reopen and repeated setup discard stale callbacks", function()
    local st, editor = fixture()
    api.nvim_win_close(st.winid, true)
    komado.open({ focus = true })
    vim.cmd("edit " .. vim.fn.fnameescape(file()))
    local buf = api.nvim_get_current_buf()
    komado.setup({ root = { require("komado.dsl").Line({ provider = "sidebar" }) } })
    st = komado.open()
    restored(st)
    equal(api.nvim_win_get_buf(editor), buf, "setup keeps pending opened file")
    api.nvim_set_current_win(st.winid)
    vim.cmd("buffer " .. buf)
    opened(st, editor, buf)
  end)

  if vim.env.TELESCOPE_RTP then
    vim.opt.runtimepath:append(vim.env.TELESCOPE_RTP)
    assert(vim.env.PLENARY_RTP, "PLENARY_RTP is required with TELESCOPE_RTP")
    vim.opt.runtimepath:append(vim.env.PLENARY_RTP)
    require("telescope").setup({ defaults = { previewer = false } })
    for _, buffer_entry in ipairs({ false, true }) do
      test("Telescope default selection (" .. (buffer_entry and "buffer" or "file") .. ")", function()
        local st, editor = fixture()
        local path = file()
        local buf = vim.fn.bufadd(path)
        vim.fn.bufload(buf)
        local entry = { value = path, display = path, ordinal = path, filename = path, lnum = 19, col = 3 }
        if buffer_entry then
          entry.bufnr = buf
        end
        local picker = require("telescope.pickers").new({}, {
          finder = require("telescope.finders").new_table({
            results = { entry },
            entry_maker = function(item)
              return item
            end,
          }),
          sorter = require("telescope.config").values.generic_sorter({}),
        })
        picker:find()
        assert(
          vim.wait(1000, function()
            return picker:get_selection() ~= nil
          end),
          "picker selects the test entry"
        )
        require("telescope.actions").select_default(picker.prompt_bufnr)
        opened(st, editor, buf, { 19, 3 })
      end)
    end
  end
  print(("PASS: %d file opening scenarios"):format(cases))
end

local ok, err = xpcall(run, debug.traceback)
komado.close()
for _, job in ipairs(jobs) do
  vim.fn.jobstop(job)
end
for _, path in ipairs(files) do
  vim.fn.delete(path)
end
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
