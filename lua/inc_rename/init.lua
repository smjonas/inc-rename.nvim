local M = {}

M.default_config = {
  cmd_name = "IncRename",
  hl_group = "Substitute",
  preview_empty_name = false,
  show_message = true,
  input_buffer_type = nil,
  post_hook = nil,
}

local dressing_config = {
  filetype = "DressingInput",
  close_window = function()
    require("dressing.input").close()
  end,
}

local state = {
  should_fetch_references = true,
  cached_lines = nil,
  input_win_id = nil,
  input_bufnr = nil,
  err = nil,
}
local backspace = vim.api.nvim_replace_termcodes("<bs>", true, false, true)
local escape = vim.api.nvim_replace_termcodes("<esc>", true, false, true)

local function set_error(msg, level)
  state.err = { msg = msg, level = level }
  state.cached_lines = nil
end

local function buf_is_visible(bufnr)
  if vim.api.nvim_buf_is_loaded(bufnr) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
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
      if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
      end
      local line = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]
      local start_col, end_col = range.start.character, range["end"].character
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
local function fetch_lsp_references(bufnr, lsp_params)
  local clients = vim.lsp.get_active_clients {
    bufnr = bufnr,
  }
  clients = vim.tbl_filter(function(client)
    return client.supports_method("textDocument/rename")
  end, clients)

  if #clients == 0 then
    set_error("[inc-rename] No active language server with rename capability")
    return
  end

  local params = lsp_params or vim.lsp.util.make_position_params()
  params.context = { includeDeclaration = true }
  vim.lsp.buf_request(bufnr, "textDocument/references", params, function(err, result, _, _)
    if err then
      set_error("[inc-rename] Error while finding references: " .. err.message, vim.lsp.log_levels.ERROR)
      return
    end
    if not result or vim.tbl_isempty(result) then
      set_error("[inc-rename] Nothing to rename", vim.lsp.log_levels.WARN)
      -- Leave command line mode when there is nothing to rename
      vim.api.nvim_feedkeys(escape, "n", false)
      return
    end
    state.cached_lines = filter_duplicates(cache_lines(result))
    -- Hack to trigger command preview again now that results have arrived
    if vim.api.nvim_get_mode().mode == "c" then
      vim.api.nvim_feedkeys("a" .. backspace, "n", false)
    end
  end)
end

local function tear_down(switch_buffer)
  state.cached_lines = nil
  state.should_fetch_references = true
  if state.input_win_id and vim.api.nvim_win_is_valid(state.input_win_id) then
    M.config.input_buffer.close_window()
    state.input_win_id = nil
    if switch_buffer then
      -- May fail (e.g. in command line window)
      pcall(vim.api.nvim_set_current_win, state.win_id)
    end
  end
end

local function initialize_input_buffer(default)
  state.win_id = vim.api.nvim_get_current_win()
  vim.ui.input({ default = default }, function() end)
  -- Open the input window and find the buffer and window IDs
  for _, win_id in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win_id)
    if vim.bo[bufnr].filetype == M.config.input_buffer.filetype then
      state.input_win_id = win_id
      state.input_bufnr = bufnr
      return
    end
  end
end

local function populate_preview_buf(preview_buf, buf_infos, preview_ns)
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
    vim.api.nvim_buf_set_lines(preview_buf, cur_line, cur_line + 1, false, { filename_info })
    vim.api.nvim_buf_add_highlight(preview_buf, preview_ns, "Comment", cur_line, 0, -1)
    cur_line = cur_line + 1

    -- Sort by line number
    table.sort(infos, function(a, b)
      return a.line_nr < b.line_nr
    end)

    for _, info in ipairs(infos) do
      local prefix = ("|%d| "):format(info.line_nr + 1)
      vim.api.nvim_buf_set_lines(preview_buf, cur_line, cur_line + 1, false, { prefix .. info.updated_line })
      for _, hl_pos in ipairs(info.hl_positions) do
        vim.api.nvim_buf_add_highlight(
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

-- Called when the user is still typing the command or the command arguments
local function incremental_rename_preview(opts, preview_ns, preview_buf)
  local new_name = opts.args
  local cur_buf = vim.api.nvim_get_current_buf()
  vim.v.errmsg = ""

  if state.input_win_id and vim.api.nvim_win_is_valid(state.input_win_id) then
    -- Add a space so the cursor can be placed after the last character
    vim.api.nvim_buf_set_lines(state.input_bufnr, 0, -1, false, { new_name .. " " })
    local _, cmd_prefix_len = vim.fn.getcmdline():find("^%s*" .. M.config.cmd_name .. "%s*")
    local cursor_pos = vim.fn.getcmdpos() - cmd_prefix_len - 1
    -- Create a fake cursor in the input buffer
    vim.api.nvim_buf_add_highlight(state.input_bufnr, preview_ns, "Cursor", 0, cursor_pos, cursor_pos + 1)
  end

  -- Store the lines of the buffer at the first invocation.
  -- should_fetch_references will be reset when the command is cancelled (see setup function).
  if state.should_fetch_references then
    state.should_fetch_references = false
    state.err = nil
    fetch_lsp_references(opts.bufnr or cur_buf, opts.lsp_params)

    if M.config.input_buffer ~= nil then
      initialize_input_buffer(opts.args)
    end
  end

  -- Started fetching references but the results did not arrive yet
  -- (or an error occurred while fetching them).
  if not state.cached_lines then
    -- Not returning 2 here somehow won't update the ui.input buffer text
    -- when state.cached_lines is still nil
    return M.config.input_buffer ~= nil and 2
  end

  if not M.config.preview_empty_name and new_name:find("^%s*$") then
    return M.config.input_buffer ~= nil and 2
  end

  -- Only used when preview_buf is not nil
  local preview_buf_infos = vim.defaulttable()

  local function apply_highlights_fn(bufnr, line_nr, line_info)
    -- rust-analyzer does not return references in ascending
    -- order for a given line number, so sort it (#47)
    table.sort(line_info, function(a, b)
      return a.start_col < b.start_col
    end)
    local offset = 0
    local updated_line = line_info[1].text
    local hl_positions = {}

    for _, info in ipairs(line_info) do
      if preview_buf or info.is_visible then
        -- Use nvim_buf_set_text instead of nvim_buf_set_lines to preserve ext-marks
        vim.api.nvim_buf_set_text(bufnr, line_nr, info.start_col + offset, line_nr, info.end_col + offset, { new_name })
        table.insert(hl_positions, {
          start_col = info.start_col + offset,
          end_col = info.start_col + #new_name + offset,
        })
        -- Offset by the length difference between the new and old names
        offset = offset + #new_name - (info.end_col - info.start_col)
      end
    end

    if preview_buf then
      -- Group by filename
      table.insert(
        preview_buf_infos[vim.api.nvim_buf_get_name(line_info[1].bufnr)],
        { updated_line = updated_line, line_nr = line_nr, hl_positions = hl_positions }
      )
    end

    for _, hl_pos in ipairs(hl_positions) do
      vim.api.nvim_buf_add_highlight(
        bufnr or opts.bufnr,
        preview_ns,
        M.config.hl_group,
        line_nr,
        hl_pos.start_col,
        hl_pos.end_col
      )
      if preview_buf then
        vim.api.nvim_buf_add_highlight(
          preview_buf,
          preview_ns,
          M.config.hl_group,
          line_nr,
          hl_pos.start_col,
          hl_pos.end_col
        )
      end
    end
  end

  for bufnr, line_info_per_bufnr in pairs(state.cached_lines) do
    for line_nr, line_info in pairs(line_info_per_bufnr) do
      apply_highlights_fn(bufnr, line_nr, line_info)
    end
  end

  if preview_buf then
    populate_preview_buf(preview_buf, preview_buf_infos, preview_ns)
  end

  state.preview_ns = preview_ns
  return 2
end

-- Sends a LSP rename request and optionally displays a message to the user showing
-- how many instances were renamed in how many files
local function perform_lsp_rename(new_name)
  local params = vim.lsp.util.make_position_params()
  params.newName = new_name

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
    vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)

    if M.config.show_message then
      local changed_instances = 0
      local changed_files = 0

      local with_edits = result.documentChanges ~= nil
      for _, change in pairs(result.documentChanges or result.changes) do
        changed_instances = changed_instances + (with_edits and #change.edits or #change)
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
    if M.config.post_hook then
      M.config.post_hook(result)
    end
  end)
end

-- Called when the command is executed (user pressed enter)
local function incremental_rename_execute(new_name)
  -- Any errors that occur in the preview function are not directly shown to the user but are stored in vim.v.errmsg.
  -- For more info, see https://github.com/neovim/neovim/issues/18910.
  if vim.v.errmsg ~= "" then
    vim.notify(
      "[inc-rename] An error occurred in the preview function. Please report this error here: https://github.com/smjonas/inc-rename.nvim/issues:\n"
        .. vim.v.errmsg,
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
  vim.api.nvim_create_user_command(cmd_name, function(opts)
    incremental_rename_execute(opts.args)
  end, { nargs = 1, addr = "lines", preview = incremental_rename_preview })
end

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

  M.config = vim.tbl_deep_extend("force", M.default_config, user_config or {})
  if M.config.input_buffer_type == "dressing" then
    M.config.input_buffer = dressing_config
  end

  local group = vim.api.nvim_create_augroup("inc-rename.nvim", { clear = true })
  -- We need to be able to tell when the command was cancelled to refetch the references.
  -- Otherwise the same variable would be renamed every time.
  vim.api.nvim_create_autocmd({ "CmdLineLeave" }, {
    group = group,
    callback = tear_down,
  })
  create_user_command(M.config.cmd_name)
end

return M
