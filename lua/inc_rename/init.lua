local M = {}

M.default_config = {
  cmd_name = "IncRename",
  hl_group = "Substitute",
  multifile_preview = true,
  show_message = true,
}

local state = {
  should_fetch_references = true,
  preview_strategy = nil,
  cached_lines = nil,
  -- Contains created namespace (used in multifile-strategy)
  preview_ns = nil,
  err = nil,
}

local function set_error(msg, level)
  state.err = { msg = msg, level = level }
  state.cached_lines = nil
end

local single_file_strategy = {
  cache_lines = function(result, bufnr)
    local cached_lines = {}
    local uri = vim.uri_from_bufnr(bufnr)
    local lsp_ranges = vim.tbl_map(
      function(item)
        return item.range
      end,
      vim.tbl_filter(function(item)
        -- Only include references from current file
        return item.uri == uri
      end, result)
    )

    for _, range in ipairs(lsp_ranges) do
      -- E.g. sumneko_lua sends ranges across multiple lines when a table value is a function, skip this range.
      if range.start.line == range["end"].line then
        local line_nr = range.start.line
        local line = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]
        local start_col, end_col = range.start.character, range["end"].character
        local line_item = { text = line, start_col = start_col, end_col = end_col }
        -- Same line was already seen
        if cached_lines[line_nr] then
          table.insert(cached_lines[line_nr], line_item)
        else
          cached_lines[line_nr] = { line_item }
        end
      end
    end
    return cached_lines
  end,
  filter_duplicates = function(cached_lines, filter_duplicates_fn)
    for line_nr, line_info in pairs(cached_lines) do
      cached_lines = filter_duplicates_fn(cached_lines, line_nr, line_info)
    end
    return cached_lines
  end,
  apply_highlights = function(cached_lines, apply_highlights_fn)
    for line_nr, line_info in pairs(cached_lines) do
      apply_highlights_fn(0, line_nr, line_info)
    end
  end,
  restore_buffer_state = function(should_fetch_references, opts)
    opts = opts or {}
    -- Only clear highlights when bufnr is explicitly passed, if not passed
    -- buffer will be cleared by command preview automatically
    if opts.bufnr and state.cached_lines then
      vim.api.nvim_buf_clear_namespace(opts.bufnr, opts.preview_ns, 0, -1)
      for line_nr, line_info in pairs(state.cached_lines) do
        for _, inter_line_info in ipairs(line_info) do
          vim.api.nvim_buf_set_lines(opts.bufnr, line_nr, line_nr + 1, true, { inter_line_info.text })
        end
      end
    end
    state.cached_lines = nil
    state.should_fetch_references = should_fetch_references
  end,
}

local multi_file_strategy = {
  cache_lines = function(result, _)
    local cached_lines = {}
    for _, res in ipairs(result) do
      local range = res.range
      -- E.g. sumneko_lua sends ranges across multiple lines when a table value is a function, skip this range
      if range.start.line == range["end"].line then
        local bufnr = vim.uri_to_bufnr(res.uri)
        -- Only need to highlight loaded buffers
        if vim.api.nvim_buf_is_loaded(bufnr) then
          if not cached_lines[bufnr] then
            cached_lines[bufnr] = {}
          end

          local line_nr = range.start.line
          local line = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]
          local start_col, end_col = range.start.character, range["end"].character
          local line_info = { text = line, start_col = start_col, end_col = end_col }
          -- Same line was already seen
          if cached_lines[bufnr][line_nr] then
            table.insert(cached_lines[bufnr][line_nr], line_info)
          else
            cached_lines[bufnr][line_nr] = { line_info }
          end
        end
      end
    end
    return cached_lines
  end,
  filter_duplicates = function(cached_lines, filter_duplicates_fn)
    for bufnr, line_info_per_bufnr in pairs(cached_lines) do
      for line_nr, line_info in pairs(line_info_per_bufnr) do
        cached_lines[bufnr] = filter_duplicates_fn(cached_lines[bufnr], line_nr, line_info)
      end
    end
    return cached_lines
  end,
  apply_highlights = function(cached_lines, apply_highlights_fn)
    for bufnr, line_info_per_bufnr in pairs(cached_lines) do
      for line_nr, line_info in pairs(line_info_per_bufnr) do
        apply_highlights_fn(bufnr, line_nr, line_info)
      end
    end
  end,
  restore_buffer_state = function(should_fetch_references, opts)
    if state.cached_lines then
      opts = opts or {}
      local cur_bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
      -- Reset highlights and buffer lines
      for bufnr, line_info_per_bufnr in pairs(state.cached_lines) do
        -- Clear highlights when buffer is explicitly passed
        if cur_bufnr or bufnr ~= cur_bufnr then
          vim.api.nvim_buf_clear_namespace(bufnr, opts.preview_ns or state.preview_ns, 0, -1)
          for line_nr, line_info in pairs(line_info_per_bufnr) do
            for _, inter_line_info in ipairs(line_info) do
              vim.api.nvim_buf_set_lines(bufnr, line_nr, line_nr + 1, true, { inter_line_info.text })
            end
          end
        end
      end
      state.cached_lines = nil
    end
    state.should_fetch_references = should_fetch_references
  end,
}

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
      return
    end

    state.cached_lines = state.preview_strategy.cache_lines(result, bufnr)

    local filter_duplicates = function(cached_lines, line_nr, line_items)
      -- Some LSP servers like bashls send items with the same positions multiple times,
      -- filter out these duplicates to avoid highlighting issues.
      local len = #line_items
      if len > 1 then
        -- This naive implementation only filters out items that are duplicates
        -- of the first item. Let's leave it like this and see if this is not enough
        -- for some language server.
        local start_col, end_col = line_items[1].start_col, line_items[1].end_col
        local filtered_lines = { line_items[1] }
        for i = 2, len do
          if line_items[i].start_col ~= start_col and line_items[i].end_col ~= end_col then
            filtered_lines[i] = line_items[i]
          end
        end
        cached_lines[line_nr] = filtered_lines
      end
      return cached_lines
    end

    state.cached_lines = state.preview_strategy.filter_duplicates(state.cached_lines, filter_duplicates)
  end)
end

-- Called when the user is still typing the command or the command arguments
local function incremental_rename_preview(opts, preview_ns, preview_buf)
  vim.v.errmsg = ""
  -- Store the lines of the buffer at the first invocation.
  -- should_fetch_references will be reset when the command is cancelled (see setup function).
  if state.should_fetch_references then
    state.should_fetch_references = false
    state.err = nil
    fetch_lsp_references(opts.bufnr or vim.api.nvim_get_current_buf(), opts.lsp_params)
    return
  end

  -- Started fetching references but the results did not arrive yet
  -- (or an error occurred while fetching them).
  if not state.cached_lines then
    return
  end

  local new_name = opts.args

  local function apply_highlights_fn(bufnr, line_nr, line_info)
    local offset = 0
    local updated_line = line_info[1].text
    local highlight_positions = {}

    for _, info in ipairs(line_info) do
      updated_line = updated_line:sub(1, info.start_col + offset)
        .. new_name
        .. updated_line:sub(info.end_col + 1 + offset)

      table.insert(highlight_positions, {
        start_col = info.start_col + offset,
        end_col = info.start_col + #new_name + offset,
      })
      -- Offset by the length difference between the new and old names
      offset = offset + #new_name - (info.end_col - info.start_col)
    end

    vim.api.nvim_buf_set_lines(bufnr or opts.bufnr, line_nr, line_nr + 1, false, { updated_line })
    if preview_buf then
      vim.api.nvim_buf_set_lines(preview_buf, line_nr, line_nr + 1, false, { updated_line })
    end

    for _, hl_pos in ipairs(highlight_positions) do
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

  state.preview_strategy.apply_highlights(state.cached_lines, apply_highlights_fn)
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
  end)
end

-- Called when the command is executed (user pressed enter)
local function incremental_rename_execute(new_name)
  -- Schedule wrapping here avoids an (uncommon) issue where buffer contents were
  -- changed by the highlight function after the rename request had already been executed.
  -- (Probably because synchronous LSP requests are not queued like Nvim API calls?)
  vim.schedule(function()
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
      perform_lsp_rename(new_name)
    end
  end)
end

-- This function can be used when using a plugin like dressing.nvim
-- (or more generally, when the new name is typed in a separate buffer).
-- That means highlighting is not available with the default vim.ui.input().
M.rename = function(opts)
  vim.validate {
    ["[inc_rename] rename function arguments"] = { opts, "table", true },
  }
  opts = opts or {}
  local ns = vim.api.nvim_create_namespace("inc_rename")
  local bufnr = vim.api.nvim_get_current_buf()
  local lsp_params = vim.lsp.util.make_position_params()

  vim.ui.input({
    prompt = "New name: ",
    default = opts.default,
    -- Misuse highlight function as callback
    highlight = function(new_name)
      incremental_rename_preview({ args = new_name, bufnr = bufnr, lsp_params = lsp_params }, ns, nil)
      return {}
    end,
  }, function(new_name)
    state.preview_strategy.restore_buffer_state(true, { bufnr = bufnr, preview_ns = ns })
    if new_name ~= nil then
      incremental_rename_execute(new_name)
    end
  end)
end

local create_user_command = function(cmd_name)
  vim.api.nvim_create_user_command(cmd_name, function(opts)
    state.preview_strategy.restore_buffer_state(true)
    incremental_rename_execute(opts.args)
  end, { nargs = 1, addr = "lines", preview = incremental_rename_preview })
end

M.setup = function(user_config)
  if vim.fn.has("nvim-0.8.0") ~= 1 then
    vim.notify(
      "[inc_rename] This plugin requires Neovim nightly (0.8). Please upgrade your Neovim version.",
      vim.lsp.log_levels.ERROR
    )
    return
  end
  M.config = vim.tbl_deep_extend("force", M.default_config, user_config or {})
  state.preview_strategy = M.config.multifile_preview and multi_file_strategy or single_file_strategy

  local id = vim.api.nvim_create_augroup("inc_rename.nvim", { clear = true })
  -- We need to be able to tell when the command was cancelled to refetch the references.
  -- Otherwise the same variable would be renamed every time.
  vim.api.nvim_create_autocmd({ "CmdLineLeave" }, {
    group = id,
    callback = vim.schedule_wrap(function()
      if state.preview_ns then
        state.preview_strategy.restore_buffer_state(true)
      end
    end),
  })
  create_user_command(M.config.cmd_name)
end

return M
