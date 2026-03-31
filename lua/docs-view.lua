local M = {}
local cfg = {}
local buf, win, prev_win, update_autocmd
local get_clients

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

local function is_real_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.api.nvim_buf_get_option(bufnr, "buftype") == ""
end

local function is_docs_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.api.nvim_buf_get_option(bufnr, "filetype") == "nvim-docs-view"
end

---------------------------------------------------------------------
-- Update docs view
---------------------------------------------------------------------

M.update = function()
  if not get_clients then
    return
  end

  if not win or not vim.api.nvim_win_is_valid(win) then
    M.toggle()
  end

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local clients = get_clients()
  if not clients or vim.tbl_isempty(clients) then
    return
  end

  local supports_hover = false
  for _, client in ipairs(clients) do
    if client.supports_method and client:supports_method("textDocument/hover") then
      supports_hover = true
      break
    end
  end
  if not supports_hover then
    return
  end

  local encoding = (clients[1] and clients[1].offset_encoding) or "utf-16"
  local params = vim.lsp.util.make_position_params(0, encoding)

  local result = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 500)
  if not result then
    return
  end

  local hover_lines
  for _, res in pairs(result) do
    if res and res.result and res.result.contents then
      hover_lines = vim.lsp.util.convert_input_to_markdown_lines(res.result.contents)
      if type(hover_lines) == "string" then
        hover_lines = { hover_lines }
      end
      hover_lines = vim.lsp.util.trim_empty_lines(hover_lines)
      break
    end
  end

  if not hover_lines or vim.tbl_isempty(hover_lines) then
    return
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, {})

  local opts = { hl_group = "Normal", max_width = cfg.width }
  if vim.lsp.util.stylize_markdown then
    vim.lsp.util.stylize_markdown(buf, hover_lines, opts)
  else
    vim.lsp.util.fancy_floating_markdown(buf, hover_lines, opts)
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

---------------------------------------------------------------------
-- Toggle docs view
---------------------------------------------------------------------

M.toggle = function()
  if win and vim.api.nvim_win_is_valid(win) then
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if update_autocmd then
      pcall(vim.api.nvim_del_autocmd, update_autocmd)
    end
    buf, win, prev_win, update_autocmd = nil, nil, nil, nil
    return
  end

  prev_win = vim.api.nvim_get_current_win()

  if cfg.position == "bottom" then
    vim.cmd("belowright new")
    vim.api.nvim_win_set_height(0, cfg.height)
  elseif cfg.position == "top" then
    vim.cmd("topleft new")
    vim.api.nvim_win_set_height(0, cfg.height)
  elseif cfg.position == "left" then
    vim.cmd("topleft vnew")
    vim.api.nvim_win_set_width(0, cfg.width)
  else
    vim.cmd("botright vnew")
    vim.api.nvim_win_set_width(0, cfg.width)
  end

  win = vim.api.nvim_get_current_win()
  buf = vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_set_name(buf, "Docs View")
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "nvim-docs-view")
  vim.api.nvim_buf_set_option(buf, "buflisted", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  if prev_win and vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end

  if cfg.update_mode == "auto" then
    local id = vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
      callback = function()
        if win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf) then
          M.update()
        else
          if update_autocmd then
            pcall(vim.api.nvim_del_autocmd, update_autocmd)
          end
          buf, win, prev_win, update_autocmd = nil, nil, nil, nil
        end
      end,
    })
    update_autocmd = id
  end
end

---------------------------------------------------------------------
-- Window-based closing logic (THE REAL FIX)
---------------------------------------------------------------------

local function no_real_buffers_visible()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if is_real_buffer(b) and not is_docs_buf(b) then
      return false
    end
  end
  return true
end

local function handle_window_closed()
  vim.schedule(function()
    -- If ANY window still shows a real buffer, do nothing
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if is_real_buffer(b) and not is_docs_buf(b) then
        return
      end
    end

    -- No real buffers visible → delete docs buffer + quit
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    -- DO NOT close the docs window manually!
    vim.cmd("qa")
  end)
end


---------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------

M.setup = function(user_cfg)
  local default_cfg = {
    position = "right",
    height = 10,
    width = 60,
    update_mode = "auto",
  }
  cfg = vim.tbl_extend("force", default_cfg, user_cfg or {})

  if vim.lsp.get_clients then
    get_clients = function()
      return vim.lsp.get_clients({ bufnr = 0 })
    end
  else
    get_clients = function()
      return vim.lsp.buf_get_clients(0)
    end
  end

  -- The ONLY event that matches your workflow
  vim.api.nvim_create_autocmd("WinClosed", {
    callback = handle_window_closed,
  })
end

---------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------

vim.api.nvim_create_user_command("DocsViewToggle", function()
  M.toggle()
end, {})

vim.api.nvim_create_user_command("DocsViewUpdate", function()
  M.update()
end, {})

return M

