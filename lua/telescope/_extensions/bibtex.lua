local has_telescope, telescope = pcall(require, 'telescope')

if not has_telescope then
  error('This plugin requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)')
end

local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')
local conf = require('telescope.config').values
local scan = require('plenary.scandir')
local path = require('plenary.path')
local putils = require('telescope.previewers.utils')
local loop = vim.loop

local depth = 1
local formats = {}
formats['tex'] = '\\cite{%s}'
formats['md'] = '@%s'
formats['markdown'] = '@%s'
formats['plain'] = '%s'
local fallback_format = 'plain'
local use_auto_format = false
local user_format = ''
local user_files = {}
local files_initialized = false
local files = {}
local search_keys = { 'author', 'year', 'title' }
local citation_format = '{{a}} ({{y}}), {{t}}.'
local citation_trim_firstname = true
local citation_max_auth = 2

local function table_contains(table, element)
  for _, value in pairs(table) do
    if value == element then
      return true
    end
  end
  return false
end

local function getBibFiles(dir)
  scan.scan_dir(dir, {
    depth = depth,
    search_pattern = '.*%.bib',
    on_insert = function(file)
      table.insert(files, { name = file, mtime = 0, entries = {} })
    end,
  })
end

local function initFiles()
  for _, file in pairs(user_files) do
    local p = path:new(file)
    if p:is_dir() then
      getBibFiles(file)
    elseif p:is_file() then
      table.insert(files, { name = file, mtime = 0, entries = {} })
    end
  end
  getBibFiles('.')
end

local function read_file(file)
  local labels = {}
  local contents = {}
  local search_relevants = {}
  local p = path:new(file)
  if not p:exists() then
    return {}
  end
  local data = p:read()
  data = data:gsub('\r', '')
  local entries = {}
  local raw_entry = ''
  while true do
    raw_entry = data:match('@%w*%s*%b{}')
    if raw_entry == nil then
      break
    end
    table.insert(entries, raw_entry)
    data = data:sub(#raw_entry + 2)
  end
  for _, entry in pairs(entries) do
    local label = entry:match('{%s*[^{},~#%\\]+,\n')
    if label then
      label = vim.trim(label:gsub('\n', ''):sub(2, -2))
      local content = vim.split(entry, '\n')
      table.insert(labels, label)
      contents[label] = content
      if table_contains(search_keys, [[label]]) then
        search_relevants[label]['label'] = label
      end
      search_relevants[label] = {}
      for _, key in pairs(search_keys) do
        local match_base = '%f[%w]' .. key
        local s = entry:match(match_base .. '%s*=%s*%b{}')
          or entry:match(match_base .. '%s*=%s*%b""')
          or entry:match(match_base .. '%s*=%s*%d+')
        if s ~= nil then
          s = s:match('%b{}') or s:match('%b""') or s:match('%d+')
          s = s:gsub('["{}\n]', ''):gsub('%s%s+', ' ')
          search_relevants[label][key] = vim.trim(s)
        end
      end
    end
  end
  return labels, contents, search_relevants
end

local function formatDisplay(entry)
  local display_string = ''
  local search_string = ''
  for _, val in pairs(search_keys) do
    if tonumber(entry[val]) ~= nil then
      display_string = display_string .. ' ' .. '(' .. entry[val] .. ')'
      search_string = search_string .. ' ' .. entry[val]
    elseif entry[val] ~= nil then
      display_string = display_string .. ', ' .. entry[val]
      search_string = search_string .. ' ' .. entry[val]
    end
  end
  return vim.trim(display_string:sub(2)), search_string:sub(2)
end

local function setup_picker()
  if not files_initialized then
    initFiles()
    files_initialized = true
  end
  local results = {}
  for _, file in pairs(files) do
    local mtime = loop.fs_stat(file.name).mtime.sec
    if mtime ~= file.mtime then
      file.entries = {}
      local result, content, search_relevants = read_file(file.name)
      for _, entry in pairs(result) do
        table.insert(results, { name = entry, content = content[entry], search_keys = search_relevants[entry] })
        table.insert(file.entries, { name = entry, content = content[entry], search_keys = search_relevants[entry] })
      end
      file.mtime = mtime
    else
      for _, entry in pairs(file.entries) do
        table.insert(results, entry)
      end
    end
  end
  return results
end

local function parse_format_string(opts)
  local format_string = nil
  if opts.format ~= nil then
    format_string = formats[opts.format]
  elseif use_auto_format then
    format_string = formats[vim.bo.filetype]
    if format_string == nil and vim.bo.filetype:match('markdown%.%a+') then
      format_string = formats['markdown']
    end
  end
  format_string = format_string or formats[user_format]
  return format_string
end

local function bibtex_picker(opts)
  opts = opts or {}
  local format_string = parse_format_string(opts)
  local results = setup_picker()
  pickers.new(opts, {
    prompt_title = 'Bibtex References',
    finder = finders.new_table({
      results = results,
      entry_maker = function(line)
        local display_string, search_string = formatDisplay(line.search_keys)
        if display_string == '' then
          display_string = line.name
        end
        if search_string == '' then
          search_string = line.name
        end
        return {
          value = search_string,
          ordinal = search_string,
          display = display_string,
          id = line,
          preview_command = function(entry, bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, results[entry.index].content)
            putils.highlighter(bufnr, 'bib')
          end,
        }
      end,
    }),
    previewer = previewers.display_content.new(opts),
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(_, map)
      actions.select_default:replace(key_append(format_string))
      map('i', '<c-e>', entry_append)
      map('i', '<c-c>', citation_append)
      return true
    end,
  }):find()
end

key_append = function(format_string)
  return function(prompt_bufnr)
    local mode = vim.api.nvim_get_mode().mode
    local entry = string.format(format_string, action_state.get_selected_entry().id.name)
    actions.close(prompt_bufnr)
    if mode == 'i' then
      vim.api.nvim_put({ entry }, '', false, true)
      vim.api.nvim_feedkeys('a', 'n', true)
    else
      vim.api.nvim_put({ entry }, '', true, true)
    end
  end
end

entry_append = function(prompt_bufnr)
  local entry = action_state.get_selected_entry().id.content
  actions.close(prompt_bufnr)
  local mode = vim.api.nvim_get_mode().mode
  if mode == 'i' then
    vim.api.nvim_put(entry, '', false, true)
    vim.api.nvim_feedkeys('a', 'n', true)
  else
    vim.api.nvim_put(entry, '', true, true)
  end
end

local function parse_line(line, exp)
  local parsed
  if line:find(exp) then
    parsed = line:match(exp) or ''
  end
  return parsed
end

local function parse_entry(entry)
  local parsed = {}
  for _, line in pairs(entry) do
    parsed.author = parse_line(line, 'author%s*=%s*["{]*(.-)["}],?$') or parsed.author or ''
    parsed.year = parse_line(line, 'year%s*=%s*["{]?(%d+)["}]?,?$') or parsed.year or ''
    parsed.title = parse_line(line, 'title%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.booktitle = parse_line(line, 'booktitle%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.date = parse_line(line, 'date%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.editor = parse_line(line, 'editor%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.isbn = parse_line(line, 'isbn%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.location = parse_line(line, 'location%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.month = parse_line(line, 'month%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.number = parse_line(line, 'number%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.pages = parse_line(line, 'pages%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.pagetotal = parse_line(line, 'pagetotal%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.publisher = parse_line(line, 'publisher%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.url = parse_line(line, 'url%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
    parsed.volume = parse_line(line, 'volume%s*=%s*["{]*(.-)["}],?$') or parsed.title or ''
  end

  return parsed
end

local function clean_titles(title)
  title = title:gsub('{', '')
  title = title:gsub('}', '')
  return title
end

local function cite_template(parsed, template)
  local citation = template
  parsed.title = clean_titles(parsed.title)
  parsed.booktitle = clean_titles(parsed.booktitle)
  local substs = {
    a = parsed.author,
    t = parsed.title,
    bt = parsed.booktitle,
    y = parsed.year,
    m = parsed.month,
    d = parsed.date,
    e = parsed.editor,
    isbn = parsed.isbn,
    l = parsed.location,
    n = parsed.number,
    p = parsed.pages,
    P = parsed.pagetotal,
    pu = parsed.publisher,
    url = parsed.url,
    vol = parsed.volume,
  }
  for k, v in pairs(substs) do
    citation = citation:gsub('{{' .. k .. '}}', v)
  end

  return citation
end

local function trim_firstname(name)
  local tmpauth = {}
  local trimmed = name
  for match in name:gmatch('(.-, %a)') do
    table.insert(tmpauth, match)
  end
  if tmpauth[1] ~= nil then
    trimmed = tmpauth[1] .. '.'
  end

  return trimmed
end

local function shorten_author(parsed, max_auth)
  local shortened = parsed.author
  local t = {}
  local sep = ' and '
  for auth in string.gmatch(parsed.author .. sep, '(.-)' .. sep) do
    if citation_trim_firstname == true then
      auth = trim_firstname(auth)
    end
    table.insert(t, auth)
  end

  if #t > max_auth then
    shortened = table.concat(t, ', ', 1, max_auth) .. ', et al.'
  elseif #t == 1 then
    shortened = trim_firstname(parsed.author)
  else
    shortened = table.concat(t, ', ', 1, #t - 1) .. ' and ' .. t[#t]
  end

  return shortened
end

local function format_citation(entry, template)
  local parsed = parse_entry(entry)

  parsed.author = shorten_author(parsed, citation_max_auth)

  local citation = cite_template(parsed, template)

  return citation
end

citation_append = function(prompt_bufnr)
  local entry = action_state.get_selected_entry().id.content
  actions.close(prompt_bufnr)
  local citation = format_citation(entry, citation_format)
  if mode == 'i' then
    vim.api.nvim_put(citation, '', false, true)
    vim.api.nvim_feedkeys('a', 'n', true)
  else
    vim.api.nvim_paste(citation, true, -1)
  end
end

return telescope.register_extension({
  setup = function(ext_config)
    depth = ext_config.depth or depth
    local custom_formats = ext_config.custom_formats or {}
    for _, format in pairs(custom_formats) do
      formats[format.id] = format.cite_marker
    end
    if ext_config.format ~= nil and formats[ext_config.format] ~= nil then
      user_format = ext_config.format
    else
      user_format = fallback_format
      use_auto_format = true
    end
    user_files = ext_config.global_files or {}
    search_keys = ext_config.search_keys or search_keys
    citation_format = ext_config.citation_format or '{{a}} ({{y}}), {{t}}.'
    citation_trim_firstname = ext_config.citation_trim_firstname or true
    citation_max_auth = ext_config.citation_max_auth or 2
  end,
  exports = {
    bibtex = bibtex_picker,
  },
})
