local M = {}

local utils

local api = vim.api

---@class inc_rename.LineInfo
---@field prev_text string
---@field start_col integer
---@field end_col integer
---@field bufnr number
---@field is_visible boolean

---@class inc_rename.State
---@field should_fetch_references boolean
---@field cached_line_infos_per_bufnr table<integer, inc_rename.LineInfo[]>?
---@field win_id integer?
---@field input_win_id integer?
---@field input_bufnr integer?
---@field preview_ns integer?
---@field err table?

---@class inc_rename.UserConfig
---@field cmd_name string?
---@field hl_group string?
---@field preview_empty_name boolean?
---@field show_message boolean?
---@field save_in_cmdline_history boolean?
---@field input_buffer_type "dressing"?
---@field post_hook fun(result: any)?

---@class inc_rename.PluginConfig : inc_rename.UserConfig
---@field input_buffer_config table

---@type inc_rename.UserConfig
M.default_config = {
  cmd_name = "IncRename",
  hl_group = "Substitute",
  preview_empty_name = false,
  show_message = true,
  save_in_cmdline_history = true,
  input_buffer_type = nil,
  post_hook = nil,
}

local dressing_config = {
  filetype = "DressingInput",
  close_window = function()
    require("dressing.input").close()
  end,
}

---@type inc_rename.State
local state = {
  should_fetch_references = true,
  cached_line_infos_per_bufnr = nil,
  win_id = nil,
  input_win_id = nil,
  input_bufnr = nil,
  preview_ns = nil,
}

local backspace = api.nvim_replace_termcodes("<bs>", true, false, true)
local ctrl_c = api.nvim_replace_termcodes("<C-c>", true, false, true)

---@param msg string
---@param level number
local function set_error(msg, level)
  state.err = { msg = msg, level = level }
  state.cached_line_infos_per_bufnr = nil
end

---@param bufnr number
---@return boolean
local function buf_is_visible(bufnr)
  if api.nvim_buf_is_loaded(bufnr) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == bufnr then
        return true
      end
    end
  end
  return false
end

local function cache_lines(result)
  local cached_lines = vim.defaulttable()
  for _, res in ipairs(result) do
    local range = res.range
    -- E.g. sumneko_lua sends ranges across multiple lines when a table value is a function, skip this range
    if range.start.line == range["end"].line then
      local bufnr = vim.uri_to_bufnr(res.uri)
      local is_visible = buf_is_visible(bufnr)
      local line_nr = range.start.line
      -- Make sure buffer is loaded before retrieving the line
      if not api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
      end
      local line = api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]
      local start_col, end_col = range.start.character, range["end"].character
      ---@type inc_rename.LineInfo
      local line_info =
        { text = line, start_col = start_col, end_col = end_col, bufnr = bufnr, is_visible = is_visible }

      -- Same line was already seen
      if cached_lines[bufnr][line_nr] then
        table.insert(cached_lines[bufnr][line_nr], line_info)
      else
        cached_lines[bufnr][line_nr] = { line_info }
      end
    end
  end
  return cached_lines
end

-- Some LSP servers like bashls send items with the same positions multiple times,
-- filter out these duplicates to avoid highlighting issues.
local function filter_duplicates(cached_lines)
  for buf, line_info_per_bufnr in pairs(cached_lines) do
    ---@param line_info inc_rename.LineInfo[]
    for line_nr, line_info in pairs(line_info_per_bufnr) do
      local len = #line_info
      if len > 1 then
        -- This naive implementation only filters out items that are duplicates
        -- of the first item. Let's leave it like this and see if someone complains.
        local start_col, end_col = line_info[1].start_col, line_info[1].end_col
        local filtered_lines = { line_info[1] }
        for i = 2, len do
          if line_info[i].start_col ~= start_col and line_info[i].end_col ~= end_col then
            filtered_lines[i] = line_info[i]
          end
        end
        cached_lines[buf][line_nr] = filtered_lines
      end
    end
  end
  return cached_lines
end

-- Get positions of LSP reference symbols
---@param bufnr number
---@param lsp_params table
local function fetch_lsp_references(bufnr, lsp_params)
  local clients = utils.get_active_clients(bufnr, "textDocument/rename")
  if #clients == 0 then
    set_error("[inc-rename] No active language server with textDocument/rename capability", vim.lsp.log_levels.WARN)
    return
  end

  local win_id = vim.api.nvim_get_current_win()
  local params = lsp_params
    or utils.make_client_position_params(win_id, {
      context = { includeDeclaration = true },
    })
  vim.lsp.buf_request(bufnr, "textDocument/references", params, function(err, result, ctx, _)
    local client_supported = vim.iter(clients):any(function(client)
      return client.id == ctx.client_id
    end)
    if not client_supported then
      return
    end
    if err then
      set_error("[inc-rename] Error while finding references: " .. err.message, vim.lsp.log_levels.ERROR)
      return
    end
    if not result or vim.tbl_isempty(result) then
      set_error("[inc-rename] Nothing to rename", vim.lsp.log_levels.WARN)
      -- Leave command line mode when there is nothing to rename
      api.nvim_feedkeys(ctrl_c, "n", false)
      return
    end
    state.cached_line_infos_per_bufnr = filter_duplicates(cache_lines(result))
    -- Hack to trigger command preview again now that results have arrived
    if api.nvim_get_mode().mode == "c" then
      api.nvim_feedkeys("a" .. backspace, "n", false)
    end
  end)
end

local function tear_down(switch_buffer)
  state.cached_line_infos_per_bufnr = nil
  state.should_fetch_references = true
  if state.input_win_id and api.nvim_win_is_valid(state.input_win_id) then
    M.config.input_buffer_config.close_window()
    state.input_win_id = nil
    if switch_buffer then
      -- May fail (e.g. in command line window)
      pcall(api.nvim_set_current_win, state.win_id)
    end
  end
  if not M.config.save_in_cmdline_history then
    -- Remove command from commandline history to not prevent the user from
    -- navigating to older entries due to the behavior of command preview (opt-in)
    vim.schedule(function()
      vim.fn.histdel("cmd", "^" .. M.config.cmd_name)
    end)
  end
end

---Leave command-line mode early when the current element cannot be renamed
---@param bufnr number
local check_can_rename_at_position = function(bufnr)
  local clients = utils.get_active_clients(bufnr, "textDocument/prepareRename")
  -- No client supporting prepareRename, but might still support rename
  if #clients == 0 then
    return
  end
  local win_id = vim.api.nvim_get_current_win()
  local params = utils.make_client_position_params(win_id)
  -- vim.lsp.buf_request may fail (#73)
  pcall(vim.lsp.buf_request, bufnr, "textDocument/prepareRename", params, function(err, result, ctx, _)
    if err then
      -- Leave command-line mode
      api.nvim_feedkeys(ctrl_c, "n", false)
      tear_down(false)
      local client = vim.lsp.get_client_by_id(ctx.client_id)
      vim.notify(
        ("[inc-rename] Cannot rename this element, server '%s' responded with: %s"):format(client.name, err.message),
        vim.lsp.log_levels.WARN
      )
      return
    end
  end)
end

local function initialize_input_buffer(default)
  state.win_id = api.nvim_get_current_win()
  vim.ui.input({ default = default }, function() end)
  -- Open the input window and find the buffer and window IDs
  for _, win_id in ipairs(api.nvim_list_wins()) do
    local bufnr = api.nvim_win_get_buf(win_id)
    if vim.bo[bufnr].filetype == M.config.input_buffer_config.filetype then
      state.input_win_id = win_id
      state.input_bufnr = bufnr
      return
    end
  end
end

M._populate_preview_buf = function(preview_buf, buf_infos, preview_ns)
  local cur_line = 0
  local sorted_buf_infos = {}
  for filename, infos in pairs(buf_infos) do
    infos.filename = filename
    infos.count = 0
    for _, info in ipairs(infos) do
      -- Simply using #infos as the count would not consider multiple instances per line
      infos.count = infos.count + #info.hl_positions
    end
    table.insert(sorted_buf_infos, infos)
  end

  -- Sort by number of lines changed, then by filename
  table.sort(sorted_buf_infos, function(a, b)
    if a.count == b.count then
      return a.filename < b.filename
    end
    return a.count < b.count
  end)

  for _, infos in ipairs(sorted_buf_infos) do
    local filename_info = ("%s (%d instance%s):"):format(infos.filename, infos.count, infos.count == 1 and "" or "s")
    api.nvim_buf_set_lines(preview_buf, cur_line, cur_line + 1, false, { filename_info })
    api.nvim_buf_add_highlight(preview_buf, preview_ns, "Comment", cur_line, 0, -1)
    cur_line = cur_line + 1

    -- Sort by line number
    table.sort(infos, function(a, b)
      return a.line_nr < b.line_nr
    end)

    local max_line_nr = infos[#infos].line_nr + 1
    for _, info in ipairs(infos) do
      local prefix = utils.get_aligned_line_prefix(info.line_nr + 1, max_line_nr)
      api.nvim_buf_set_lines(preview_buf, cur_line, cur_line + 1, false, { prefix .. info.updated_line })
      for _, hl_pos in ipairs(info.hl_positions) do
        api.nvim_buf_add_highlight(
          preview_buf,
          preview_ns,
          M.config.hl_group,
          cur_line,
          hl_pos.start_col + #prefix,
          hl_pos.end_col + #prefix
        )
      end
      cur_line = cur_line + 1
    end
  end
end

---@param new_name string
---@param input_bufnr number
---@param preview_ns number
---@param cmd_name string
local function update_input_buffer(new_name, input_bufnr, preview_ns, cmd_name)
  -- Add a space so the cursor can be placed after the last character
  api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { new_name .. " " })
  local _, cmd_prefix_len = vim.fn.getcmdline():find("^%s*" .. cmd_name .. "%s*")
  local cursor_pos = vim.fn.getcmdpos() - cmd_prefix_len - 1
  -- Create a fake cursor in the input buffer
  api.nvim_buf_add_highlight(input_bufnr, preview_ns, "Cursor", 0, cursor_pos, cursor_pos + 1)
end

---@param bufnr integer
---@param line_nr number
---@param line_infos inc_rename.LineInfo[]
---@param preview_fn_args table
function M._apply_highlights_fn(bufnr, line_nr, line_infos, preview_fn_args)
  local new_name = preview_fn_args.new_name
  local preview_ns = preview_fn_args.preview_ns
  local opts = preview_fn_args.opts
  -- Rust-analyzer does not return references in ascending
  -- order for a given line number, so sort it (#47)
  table.sort(line_infos, function(a, b)
    return a.start_col < b.start_col
  end)
  local offset = 0
  local hl_positions = {}

  for _, info in ipairs(line_infos) do
    if info.is_visible then
      -- Use nvim_buf_set_text instead of nvim_buf_set_lines to preserve ext-marks
      api.nvim_buf_set_text(bufnr, line_nr, info.start_col + offset, line_nr, info.end_col + offset, { new_name })
      table.insert(hl_positions, {
        start_col = info.start_col + offset,
        end_col = info.start_col + #new_name + offset,
      })
      -- Offset by the length difference between the new and old names
      offset = offset + #new_name - (info.end_col - info.start_col)
    end
  end

  for _, hl_pos in ipairs(hl_positions) do
    api.nvim_buf_add_highlight(
      bufnr or opts.bufnr,
      preview_ns,
      M.config.hl_group,
      line_nr,
      hl_pos.start_col,
      hl_pos.end_col
    )
  end
end

---@param bufnr integer
---@param buf_visible boolean
---@param preview_buf integer
---@param preview_buf_infos table<string, table>
---@param line_nr number
---@param line_infos inc_rename.LineInfo[]
---@param preview_fn_args table
function M._apply_highlights_fn_with_preview_buf(
  bufnr,
  buf_visible,
  preview_buf,
  preview_buf_infos,
  line_nr,
  line_infos,
  preview_fn_args
)
  local new_name = preview_fn_args.new_name
  local preview_ns = preview_fn_args.preview_ns
  local opts = preview_fn_args.opts
  -- Rust-analyzer does not return references in ascending
  -- order for a given line number, so sort it (#47)
  table.sort(line_infos, function(a, b)
    return a.start_col < b.start_col
  end)
  local offset = 0
  local hl_positions = {}
  local original_line = api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]

  for _, info in ipairs(line_infos) do
    -- Use nvim_buf_set_text instead of nvim_buf_set_lines to preserve ext-marks
    api.nvim_buf_set_text(bufnr, line_nr, info.start_col + offset, line_nr, info.end_col + offset, { new_name })
    table.insert(hl_positions, {
      start_col = info.start_col + offset,
      end_col = info.start_col + #new_name + offset,
      is_visible = info.is_visible,
    })
    -- Offset by the length difference between the new and old names
    offset = offset + #new_name - (info.end_col - info.start_col)
  end

  local updated_line = api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]
  if not buf_visible then
    -- Since buffer is not visible, must revert to original line contents.
    api.nvim_buf_set_text(bufnr, line_nr, 0, line_nr, -1, { original_line })
  end

  for _, hl_pos in ipairs(hl_positions) do
    if hl_pos.is_visible then
      api.nvim_buf_add_highlight(
        bufnr or opts.bufnr,
        preview_ns,
        M.config.hl_group,
        line_nr,
        hl_pos.start_col,
        hl_pos.end_col
      )
    end
    api.nvim_buf_add_highlight(preview_buf, preview_ns, M.config.hl_group, line_nr, hl_pos.start_col, hl_pos.end_col)
  end

  local filename = api.nvim_buf_get_name(bufnr)
  table.insert(
    preview_buf_infos[filename],
    { updated_line = updated_line, line_nr = line_nr, hl_positions = hl_positions }
  )
end

-- Called when the user is still typing the command or the command arguments
---@param opts table
---@param preview_ns number
---@param preview_buf number?
local function incremental_rename_preview(opts, preview_ns, preview_buf)
  local new_name = opts.args
  local cur_buf = api.nvim_get_current_buf()
  vim.v.errmsg = ""

  if state.input_win_id and api.nvim_win_is_valid(state.input_win_id) then
    update_input_buffer(new_name, state.input_bufnr, preview_ns, M.config.cmd_name)
  end

  -- Store the lines of the buffer at the first invocation.
  -- should_fetch_references will be reset when the command is cancelled (see setup function).
  if state.should_fetch_references then
    check_can_rename_at_position(opts.bufnr or cur_buf)

    state.should_fetch_references = false
    state.err = nil
    fetch_lsp_references(opts.bufnr or cur_buf, opts.lsp_params)

    if M.config.input_buffer_config ~= nil then
      initialize_input_buffer(opts.args)
    end
  end

  -- Started fetching references but the results did not arrive yet
  -- (or an error occurred while fetching them).
  if not state.cached_line_infos_per_bufnr then
    -- Not returning 2 here somehow won't update the ui.input buffer text
    -- when state.cached_line_infos_per_bufnr is still nil
    return M.config.input_buffer_config ~= nil and 2
  end

  if not M.config.preview_empty_name and new_name:find("^%s*$") then
    return M.config.input_buffer_config ~= nil and 2
  end

  -- Only used when preview_buf is not nil
  local preview_buf_infos = vim.defaulttable()

  local preview_fn_args = {
    new_name = new_name,
    preview_ns = preview_ns,
    opts = opts,
  }
  for bufnr, line_infos_per_bufnr in pairs(state.cached_line_infos_per_bufnr) do
    local buf_visible = buf_is_visible(bufnr)
    for line_nr, line_infos in pairs(line_infos_per_bufnr) do
      if preview_buf then
        M._apply_highlights_fn_with_preview_buf(
          bufnr,
          buf_visible,
          preview_buf,
          preview_buf_infos,
          line_nr,
          line_infos,
          preview_fn_args
        )
      else
        M._apply_highlights_fn(bufnr, line_nr, line_infos, preview_fn_args)
      end
    end
  end

  if preview_buf then
    M._populate_preview_buf(preview_buf, preview_buf_infos, preview_ns)
  end
  return 2
end

local function show_success_message(result)
  local changed_instances = 0
  local changed_files = 0

  local with_edits = result.documentChanges ~= nil
  for _, change in pairs(result.documentChanges or result.changes) do
    changed_instances = changed_instances + (with_edits and #(change.edits or {}) or #change)
    changed_files = changed_files + 1
  end

  local message = string.format(
    "Renamed %s instance%s in %s file%s",
    changed_instances,
    changed_instances == 1 and "" or "s",
    changed_files,
    changed_files == 1 and "" or "s"
  )
  vim.notify(message)
end

-- Sends a LSP rename request and optionally displays a message to the user showing
-- how many instances were renamed in how many files
---@param new_name string
local function perform_lsp_rename(new_name)
  local win_id = vim.api.nvim_get_current_win()
  local params = utils.make_client_position_params(win_id, { newName = new_name })
  vim.lsp.buf_request(0, "textDocument/rename", params, function(err, result, ctx, _)
    if err and err.message then
      vim.notify("[inc-rename] Error while renaming: " .. err.message, vim.lsp.log_levels.ERROR)
      return
    end

    if not result or vim.tbl_isempty(result) then
      set_error("[inc-rename] Nothing renamed", vim.lsp.log_levels.WARN)
      return
    end

    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if not client then
      vim.notify("[inc-rename] Error while renaming (invalid client ID)", vim.lsp.log_levels.ERROR)
      return
    end
    vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)

    if M.config.show_message then
      show_success_message(result)
    end
    if M.config.post_hook then
      M.config.post_hook(result)
    end
  end)
end

-- Called when the command is executed (user pressed enter)
---@param new_name string
local function incremental_rename_execute(new_name)
  -- Any errors that occur in the preview function are not directly shown to the user but are stored in vim.v.errmsg.
  -- For more info, see https://github.com/neovim/neovim/issues/18910.
  if vim.v.errmsg ~= "" then
    local client_names = vim.tbl_map(function(client)
      return client.name
    end, utils.get_active_clients(0))
    local nvim_version = tostring(vim.version())
    vim.notify(
      ([[
      "[inc-rename] An error occurred in the preview function. Please report this error here: https://github.com/smjonas/inc-rename.nvim/issues:
%s
Nvim version: %s
Active language servers: %s
Buffer name: %s]]):format(vim.v.errmsg, nvim_version, vim.inspect(client_names), api.nvim_buf_get_name(0)),
      vim.lsp.log_levels.ERROR
    )
  elseif state.err then
    vim.notify(state.err.msg, state.err.level)
  else
    tear_down(true)
    perform_lsp_rename(new_name)
  end
end

M.rename = function()
  vim.notify_once(
    "[inc-rename] The rename function has been removed, you no longer need to call it. Please check the readme for details.",
    vim.lsp.log_levels.WARN
  )
end

local create_user_command = function(cmd_name)
  api.nvim_create_user_command(cmd_name, function(opts)
    incremental_rename_execute(opts.args)
  end, { nargs = 1, addr = "lines", preview = incremental_rename_preview })
end

---@param user_config inc_rename.UserConfig
M.setup = function(user_config)
  -- vim.defaulttable has been added after the command preview feature
  -- so make sure the current 0.8 version is recent enough
  if vim.fn.has("nvim-0.8.0") ~= 1 or not vim.defaulttable then
    vim.notify(
      "[inc-rename] This plugin requires at least Neovim 0.8 (stable). Please upgrade your Neovim version.",
      vim.lsp.log_levels.ERROR
    )
    return
  end

  if vim.g.loaded_traces_plugin == 1 then
    vim.notify(
      "[inc-rename] This plugin is incompatible with traces.vim. Please uninstall one of them to proceed.",
      vim.log.levels.ERROR
    )
    return
  end
  utils = require("inc_rename.utils")

  ---@type inc_rename.PluginConfig
  ---@diagnostic disable-next-line: assign-type-mismatch
  M.config = vim.tbl_deep_extend("force", M.default_config, user_config or {})
  if M.config.input_buffer_type == "dressing" then
    M.config.input_buffer_config = dressing_config
  end

  local group = api.nvim_create_augroup("inc-rename.nvim", { clear = true })
  -- We need to be able to tell when the command was cancelled to refetch the references.
  -- Otherwise the same variable would be renamed every time.
  api.nvim_create_autocmd({ "CmdLineLeave" }, {
    group = group,
    callback = tear_down,
  })
  create_user_command(M.config.cmd_name)
end

return M
