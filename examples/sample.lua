-- komado.nvim sample sidebar.
--
-- A single sidebar window stacks several self-contained "modules" vertically, each with its own `update` triggers and helpers.
-- Modules below are intentionally independent — copy any of them into your own config and rearrange freely.
--
-- Run via:  nix run .#demo
-- Or:       nvim --cmd "set rtp+=." -c "luafile examples/sample.lua" -c KomadoOpen

local komado = require("komado")
local Line = require("komado.dsl").Line
local utils = require("komado.utils")

-- ─────────────────────────────────────────────────────────────────────────
-- Module: Header (static)
-- ─────────────────────────────────────────────────────────────────────────
local Header = {
  Line({
    { provider = "■ ", hl = "Statement" },
    { provider = "komado", hl = "Title" },
    { provider = " sample", hl = "Comment" },
  }),
  utils.separator("─", "Comment"),
}

local Spacer = Line({ provider = "" })

-- ─────────────────────────────────────────────────────────────────────────
-- Module: FileInfo
--   Re-renders on BufEnter / DirChanged.
--   Uses parent init() to compute values once per evaluation and have children pull them via `self.*`.
-- ─────────────────────────────────────────────────────────────────────────
local FileInfo = {
  update = { "BufEnter", "DirChanged" },
  init = function(self)
    self.cwd = vim.fn.getcwd()
    self.bufname = vim.fn.bufname("%")
    self.ft = vim.bo.filetype
  end,
  Line({ provider = "▸ File", hl = "Statement" }),
  Line({
    { provider = "  cwd: ", hl = "Comment" },
    {
      provider = function(self)
        return self.cwd
      end,
    },
  }),
  Line({
    { provider = "  buf: ", hl = "Comment" },
    {
      provider = function(self)
        return self.bufname ~= "" and self.bufname or "[No Name]"
      end,
    },
  }),
  Line({
    { provider = "  ft : ", hl = "Comment" },
    {
      provider = function(self)
        return self.ft ~= "" and self.ft or "-"
      end,
    },
  }),
}

-- ─────────────────────────────────────────────────────────────────────────
-- Module: Buffers
--   Listed buffers with `<CR>` to switch and `d` to delete.
--   `<LeftMouse>` is auto-mapped to the same dispatch as `<CR>`, so clicking a row works.
-- ─────────────────────────────────────────────────────────────────────────
local function listed_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      out[#out + 1] = {
        bufnr = b,
        modified = vim.bo[b].modified,
        current = b == vim.api.nvim_get_current_buf(),
        display = (name ~= "" and vim.fn.fnamemodify(name, ":~:.")) or "[No Name]",
      }
    end
  end
  return out
end

local Buffers = {
  update = { "BufAdd", "BufDelete", "BufEnter", "BufModifiedSet" },
  Line({ provider = "▸ Buffers", hl = "Statement" }),
  utils.expandable_list(function()
    return listed_buffers()
  end, function(item)
    local marker = item.current and "▸ " or "  "
    local mod = item.modified and " [+]" or ""
    return Line({
      on_select = function(_, ctx)
        vim.cmd("wincmd p")
        vim.api.nvim_set_current_buf(ctx.ctx.item.bufnr)
      end,
      { provider = marker, hl = item.current and "Statement" or "Comment" },
      { provider = tostring(item.bufnr), hl = "Number" },
      { provider = " " },
      { provider = item.display, hl = item.current and "Statement" or "Normal" },
      { provider = mod, hl = "WarningMsg" },
    })
  end),
}

-- ─────────────────────────────────────────────────────────────────────────
-- Module: GitStatus
--   A small `git status --short` view with foldable sections.
-- ─────────────────────────────────────────────────────────────────────────
local function git_start_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    local stat = vim.uv.fs_stat(name)
    if stat and stat.type == "directory" then
      return name
    end
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

local function git_lines(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return lines
end

local function git_root()
  local lines = git_lines(git_start_dir(), { "rev-parse", "--show-toplevel" })
  return lines and lines[1] ~= "" and lines[1] or nil
end

local function git_status()
  local root = git_root()
  if not root then
    return nil
  end

  local lines = git_lines(root, { "status", "--short", "--branch", "--untracked-files=normal" }) or {}
  local status = {
    root = root,
    branch = "unknown",
    staged = {},
    unstaged = {},
    untracked = {},
  }

  for _, line in ipairs(lines) do
    if line:sub(1, 2) == "##" then
      status.branch = line:sub(4)
    elseif line ~= "" then
      local xy = line:sub(1, 2)
      local x = xy:sub(1, 1)
      local y = xy:sub(2, 2)
      local path = line:sub(4)
      if xy == "??" then
        status.untracked[#status.untracked + 1] = { code = "?", path = path }
      else
        if x ~= " " then
          status.staged[#status.staged + 1] = { code = x, path = path }
        end
        if y ~= " " then
          status.unstaged[#status.unstaged + 1] = { code = y, path = path }
        end
      end
    end
  end

  return status
end

local function git_file_target(path)
  return path:match(".+ %-> (.+)$") or path
end

local function git_rows(status, collapsed)
  local rows = {
    {
      kind = "root",
      label = "Git",
      branch = status and status.branch or "not a git repository",
      clean = status and #status.staged == 0 and #status.unstaged == 0 and #status.untracked == 0,
    },
  }

  if not status then
    return rows
  end

  local sections = {
    { key = "staged", label = "Staged", items = status.staged },
    { key = "unstaged", label = "Unstaged", items = status.unstaged },
    { key = "untracked", label = "Untracked", items = status.untracked },
  }

  for _, section in ipairs(sections) do
    if #section.items > 0 then
      rows[#rows + 1] = {
        kind = "section",
        key = section.key,
        label = section.label,
        count = #section.items,
        collapsed = collapsed[section.key],
      }
      if not collapsed[section.key] then
        for _, item in ipairs(section.items) do
          rows[#rows + 1] = {
            kind = "file",
            root = status.root,
            code = item.code,
            path = item.path,
          }
        end
      end
    end
  end

  if #rows == 1 and rows[1].clean then
    rows[#rows + 1] = { kind = "message", text = "  clean" }
  end
  return rows
end

local git_status_hl = {
  ["?"] = "Comment",
  A = "String",
  C = "Identifier",
  D = "ErrorMsg",
  M = "WarningMsg",
  R = "Identifier",
  U = "ErrorMsg",
}

local GitStatus = {
  static = {
    collapsed = {
      staged = false,
      unstaged = false,
      untracked = false,
    },
  },
  init = function(self)
    self.status = git_status()
    self.rows = git_rows(self.status, self.collapsed)
  end,
  {
    update = { "BufEnter", "BufWritePost", "DirChanged", "FocusGained", "ShellCmdPost" },
  },
  utils.expandable_list(function(self)
    return self.rows
  end, function(item)
    if item.kind == "root" then
      return Line({
        { provider = "▸ Git", hl = "Statement" },
        { provider = " " },
        { provider = item.branch, hl = item.clean and "String" or "Comment" },
      })
    end

    if item.kind == "section" then
      return Line({
        on_select = function(self, ctx)
          local key = ctx.ctx.item.key
          self.collapsed[key] = not self.collapsed[key]
          komado.redraw()
        end,
        { provider = item.collapsed and "  ▸ " or "  ▾ ", hl = "Comment" },
        { provider = item.label, hl = "Identifier" },
        { provider = " " },
        { provider = tostring(item.count), hl = "Number" },
      })
    end

    if item.kind == "file" then
      return Line({
        on_select = function(_, ctx)
          local selected = ctx.ctx.item
          vim.cmd("wincmd p")
          vim.cmd("edit " .. vim.fn.fnameescape(selected.root .. "/" .. git_file_target(selected.path)))
        end,
        { provider = "    " },
        { provider = item.code, hl = git_status_hl[item.code] or "Comment" },
        { provider = "  " },
        { provider = item.path },
      })
    end

    return Line({ provider = item.text, hl = "Comment" })
  end),
}

-- ─────────────────────────────────────────────────────────────────────────
-- Module: Marks (conditional — renders buffer-local and global marks)
-- ─────────────────────────────────────────────────────────────────────────
local function collect_marks()
  local out = {}
  local current_bufnr = vim.api.nvim_get_current_buf()
  local function entry(m)
    local pos = m.pos or {}
    local bufnr = pos[1] or 0
    local file = m.file or ""
    if file == "" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
      file = vim.api.nvim_buf_get_name(bufnr)
    end
    return {
      mark = m.mark:sub(2),
      bufnr = bufnr > 0 and bufnr or nil,
      file = file,
      lnum = pos[2] or 0,
      col = math.max(0, (pos[3] or 1) - 1),
    }
  end

  for _, m in ipairs(vim.fn.getmarklist(current_bufnr)) do
    if m.mark:match("^'[a-z]$") then
      out[#out + 1] = entry(m)
    end
  end

  for _, m in ipairs(vim.fn.getmarklist()) do
    if m.mark:match("^'[A-Z0-9]$") then
      out[#out + 1] = entry(m)
    end
  end
  return out
end

-- Note: condition() runs *before* init() in komado, so any value consumed by condition must be computed inside it (or before _eval).
-- Here we side-effect into self.marks so the children can read it via metatable.
local Marks = {
  update = { "BufEnter", "MarkSet", pattern = "*" },
  condition = function(self)
    self.marks = collect_marks()
    return #self.marks > 0
  end,
  Line({ provider = "▸ Marks", hl = "Statement" }),
  utils.expandable_list(function(self)
    return self.marks
  end, function(m)
    return Line({
      on_select = function(_, ctx)
        local mark = ctx.ctx.item
        vim.cmd("wincmd p")
        if mark.bufnr and vim.api.nvim_buf_is_valid(mark.bufnr) then
          vim.api.nvim_set_current_buf(mark.bufnr)
        elseif mark.file ~= "" then
          vim.cmd("edit " .. vim.fn.fnameescape(mark.file))
        else
          return
        end
        if mark.lnum > 0 then
          pcall(vim.api.nvim_win_set_cursor, 0, { mark.lnum, mark.col or 0 })
        end
      end,
      { provider = "  " },
      { provider = m.mark, hl = "Identifier" },
      { provider = "  " },
      { provider = m.file ~= "" and vim.fn.fnamemodify(m.file, ":t") or "?", hl = "Directory" },
      { provider = ":", hl = "Comment" },
      { provider = tostring(m.lnum), hl = "Number" },
    })
  end),
}

-- ─────────────────────────────────────────────────────────────────────────
-- Module: Clock
--   Driven by a 1s libuv timer that fires `User KomadoTick`.
--   komado's update pipeline invalidates the per-state cache for any component listening on that event and schedules a redraw, so the displayed time advances even when the user is idle (CursorHold alone wouldn't be enough).
-- ─────────────────────────────────────────────────────────────────────────
local clock_timer
local function ensure_clock_timer()
  if clock_timer then
    return
  end
  clock_timer = vim.uv.new_timer()
  if not clock_timer then
    return
  end
  clock_timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "KomadoTick",
        modeline = false,
      })
    end)
  )
end
ensure_clock_timer()

local Clock = {
  update = { "User", pattern = "KomadoTick" },
  Line({
    { provider = "▸ ", hl = "Comment" },
    {
      provider = function()
        return os.date("%Y-%m-%d")
      end,
      hl = "Comment",
    },
    utils.horizontal_align(),
    {
      provider = function()
        return os.date("%H:%M:%S")
      end,
      hl = "String",
    },
  }),
}

-- ─────────────────────────────────────────────────────────────────────────
-- Compose: a single sidebar that stacks the modules vertically.
-- `utils.vertical_align()` behaves like statusline's `%=`, filling the remaining height before Clock.
-- ─────────────────────────────────────────────────────────────────────────
komado.setup({
  -- Width = 30% of editor width, but never below 38 nor above 80 columns.
  window = {
    position = "left",
    size = { ratio = 0.3, min = 38, max = 80 },
  },
  buffer = { filetype = "komado-sample" },
  -- `<CR>` and `<LeftMouse>` are auto-mapped to invoke the row's `on_select` (each Line above defines its own).
  -- Override either by listing it here.
  mappings = {
    ["q"] = function()
      komado.close()
    end,
    ["r"] = function()
      komado.redraw()
    end,
    ["d"] = "delete_buffer",
  },
  commands = {
    delete_buffer = function(_, ctx)
      if not ctx or not ctx.ctx or not ctx.ctx.item or not ctx.ctx.item.bufnr then
        return
      end
      pcall(vim.api.nvim_buf_delete, ctx.ctx.item.bufnr, { force = false })
      komado.redraw()
    end,
  },
  root = {
    Header,
    Spacer,
    FileInfo,
    Spacer,
    Buffers,
    Spacer,
    GitStatus,
    Spacer,
    Marks,
    utils.vertical_align(),
    Clock,
  },
})

vim.api.nvim_create_user_command("KomadoOpen", function()
  komado.open()
end, {})
vim.api.nvim_create_user_command("KomadoClose", function()
  komado.close()
end, {})
vim.api.nvim_create_user_command("KomadoToggle", function()
  komado.toggle()
end, {})
vim.api.nvim_create_user_command("KomadoRedraw", function()
  komado.redraw()
end, {})
