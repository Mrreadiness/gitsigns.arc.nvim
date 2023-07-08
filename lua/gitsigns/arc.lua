local async = require('gitsigns.async')
local scheduler = require('gitsigns.async').scheduler

local log = require('gitsigns.debug.log')
local util = require('gitsigns.util')
local subprocess = require('gitsigns.subprocess')

local gs_config = require('gitsigns.config')
local config = gs_config.config

local gs_hunks = require('gitsigns.hunks')

local uv = vim.loop
local startswith = vim.startswith

local dprint = require('gitsigns.debug.log').dprint
local eprint = require('gitsigns.debug.log').eprint
local err = require('gitsigns.message').error

local M = {}

--- @param file string
--- @return boolean
local function in_arc_dir(file)
  for _, p in ipairs(vim.split(file, util.path_sep)) do
    if p == '.arc' then
      return true
    end
  end
  return false
end

--- @class Gitsigns.GitObj
--- @field file string
--- @field encoding string
--- @field i_crlf boolean Object has crlf
--- @field w_crlf boolean Working copy has crlf
--- @field mode_bits string
--- @field object_name string
--- @field relpath string
--- @field orig_relpath? string Use for tracking moved files
--- @field repo Gitsigns.Repo
--- @field has_conflicts? boolean
local Obj = {}

M.Obj = Obj

--- @class Gitsigns.Repo
--- @field gitdir string
--- @field toplevel string
--- @field detached boolean
--- @field abbrev_head string
--- @field username string
local Repo = {}
M.Repo = Repo

--- @class Gitsigns.Version
--- @field major integer
--- @field minor integer
--- @field patch integer

--- @param version string
--- @return Gitsigns.Version
local function parse_version(version)
  assert(version:match('arc version %d+'), 'Invalid arc version: ' .. version)
  local ret = {}
  ret.major = version:match('%d+')
  ret.minor = 0
  ret.patch = 0

  return ret
end

--- @param args string[]
--- @param spec? Gitsigns.JobSpec
--- @return string[] stdout, string? stderr
local git_command = async.create(function(args, spec)
  spec = spec or {}
  spec.command = spec.command or 'arc'
  spec.args = args

  --- @type integer, integer, string?, string?
  local _, _, stdout, stderr = async.wait(2, subprocess.run_job, spec)

  if not spec.suppress_stderr then
    if stderr then
      local cmd_str = table.concat({ spec.command, unpack(args) }, ' ')
      log.eprintf("Received stderr when running command\n'%s':\n%s", cmd_str, stderr)
    end
  end

  if spec.json and stdout then
    local json = require("json")
    local status, stdout_json = pcall(json.decode, stdout)
    if status then
      return stdout_json, stderr
    end
  end

  local stdout_lines = vim.split(stdout or '', '\n', { plain = true })

  -- If stdout ends with a newline, then remove the final empty string after
  -- the split
  if stdout_lines[#stdout_lines] == '' then
    stdout_lines[#stdout_lines] = nil
  end

  if log.verbose then
    log.vprintf('%d lines:', #stdout_lines)
    for i = 1, math.min(10, #stdout_lines) do
      log.vprintf('\t%s', stdout_lines[i])
    end
  end

  return stdout_lines, stderr
end, 2)

--- @param file_cmp string
--- @param file_buf string
--- @param indent_heuristic? boolean
--- @param diff_algo string
--- @return string[] stdout, string? stderr
function M.diff(file_cmp, file_buf, indent_heuristic, diff_algo)
  -- local spec = { command = 'git' }  -- TODO
  return git_command({
    '-c',
    'core.safecrlf=false',
    'diff',
    '--color=never',
    '--' .. (indent_heuristic and '' or 'no-') .. 'indent-heuristic',
    '--diff-algorithm=' .. diff_algo,
    '--patch-with-raw',
    '--unified=0',
    file_cmp,
    file_buf,
  })
end

--- @param arcdir string
--- @param path string
--- @param cmd? string
--- @return string?
local function process_abbrev_head(arcdir, path, cmd)
  if not arcdir then
    return nil
  end
  local info = git_command({ 'info' }, {
    command = cmd or 'arc',
    supress_stderr = true,
    cwd = path,
  })
  for _, v in ipairs(info) do
    if startswith(v, 'detached: true') then
      return 'HEAD'
    end
    if (startswith(v, 'branch:')) then
      return v:sub(9)
    end
  end
  print("Can't find branch or detached in 'arc info'")
  return nil
end

--- @class Gitsigns.RepoInfo
--- @field gitdir string
--- @field toplevel string
--- @field detached boolean
--- @field abbrev_head string

--- @param path string
--- @param cmd? string
--- @param gitdir? string
--- @param toplevel? string
--- @return Gitsigns.RepoInfo
function M.get_repo_info(path, cmd, gitdir, toplevel)
  scheduler()

  local results = git_command({
    'rev-parse', '--show-toplevel', '--arc-dir',
  }, {
    command = cmd or 'arc',
    supress_stderr = true,
    cwd = path,
  })

  local arcdir = results[2]

  local ret = {}
  ret.abbrev_head = process_abbrev_head(arcdir, path, cmd)
  ret.gitdir = arcdir
  ret.toplevel = results[1]
  ret.detached = ret.toplevel and ret.gitdir ~= ret.toplevel .. '/.arc'


  return ret
end

M.set_version = function(version)
  if version ~= 'auto' then
    M.version = parse_version(version)
    return
  end
  local results = M.command({ '--version' })
  local line = results[1]
  assert(startswith(line, 'arc version'), 'Unexpected output: ' .. line)
  M.version = parse_version(line)
end

--------------------------------------------------------------------------------
-- Git repo object methods
--------------------------------------------------------------------------------

--- Run git command the with the objects gitdir and toplevel
--- @param args string[]
--- @param spec? Gitsigns.JobSpec
--- @return string[] stdout, string? stderr
function Repo:command(args, spec)
  spec = spec or {}
  spec.cwd = self.toplevel

  return git_command({ unpack(args) }, spec)
end

--- @return string[]
function Repo:files_changed()
  --- @type string[]
  local results = self:command({ 'status', '--short' })

  local ret = {} --- @type string[]
  for _, line in ipairs(results) do
    if line:sub(1, 2):match('^.M') then
      ret[#ret + 1] = line:sub(4, -1)
    end
  end
  return ret
end

--- @param ... integer
--- @return string
local function make_bom(...)
  local r = {}
  ---@diagnostic disable-next-line:no-unknown
  for i, a in ipairs({ ... }) do
    ---@diagnostic disable-next-line:no-unknown
    r[i] = string.char(a)
  end
  return table.concat(r)
end

local BOM_TABLE = {
  ['utf-8'] = make_bom(0xef, 0xbb, 0xbf),
  ['utf-16le'] = make_bom(0xff, 0xfe),
  ['utf-16'] = make_bom(0xfe, 0xff),
  ['utf-16be'] = make_bom(0xfe, 0xff),
  ['utf-32le'] = make_bom(0xff, 0xfe, 0x00, 0x00),
  ['utf-32'] = make_bom(0xff, 0xfe, 0x00, 0x00),
  ['utf-32be'] = make_bom(0x00, 0x00, 0xfe, 0xff),
  ['utf-7'] = make_bom(0x2b, 0x2f, 0x76),
  ['utf-1'] = make_bom(0xf7, 0x54, 0x4c),
}

local function strip_bom(x, encoding)
  local bom = BOM_TABLE[encoding]
  if bom and vim.startswith(x, bom) then
    return x:sub(bom:len() + 1)
  end
  return x
end

--- @param encoding string
--- @return boolean
local function iconv_supported(encoding)
  -- TODO(lewis6991): needs https://github.com/neovim/neovim/pull/21924
  if vim.startswith(encoding, 'utf-16') then
    return false
  elseif vim.startswith(encoding, 'utf-32') then
    return false
  end
  return true
end

--- Get version of file in the index, return array lines
--- @param object string
--- @param encoding? string
--- @return string[] stdout, string? stderr
function Repo:get_show_text(object, encoding)
  local stdout, stderr = self:command({ 'show', '--git', object }, { suppress_stderr = true })

  if encoding and encoding ~= 'utf-8' and iconv_supported(encoding) then
    stdout[1] = strip_bom(stdout[1], encoding)
    for i, l in ipairs(stdout) do
      --- @diagnostic disable-next-line:param-type-mismatch
      stdout[i] = vim.iconv(l, encoding, 'utf-8')
    end
  end

  return stdout, stderr
end

function Repo:update_abbrev_head()
  self.abbrev_head = M.get_repo_info(self.toplevel).abbrev_head
end

--- @param dir string
function Repo.find_username(dir)
  local self = setmetatable({}, { __index = Repo })
  local info = self:command({ '-un' }, {
    command = 'id',
    supress_stderr = true,
    cwd = dir,
  })
  if #info == 0 then
    print("Can't find login in 'id -un'")
    return ''
  end
  return info[1]
end

--- @param dir string
--- @param gitdir? string
--- @param toplevel? string
--- @return Gitsigns.Repo
function Repo.new(dir, gitdir, toplevel)
  local self = setmetatable({}, { __index = Repo })

  self.username = self.find_username(dir)
  local res = M.get_repo_info(dir)
  self.toplevel = res.toplevel
  self.gitdir = res.gitdir
  self.abbrev_head = res.abbrev_head

  return self
end

--------------------------------------------------------------------------------
-- Git object methods
--------------------------------------------------------------------------------

--- Run git command the with the objects gitdir and toplevel
--- @param args string[]
--- @param spec? Gitsigns.JobSpec
--- @return string[] stdout, string? stderr
function Obj:command(args, spec)
  return self.repo:command(args, spec)
end

--- @param update_relpath? boolean
--- @param silent? boolean
--- @return boolean
function Obj:update_file_info(update_relpath, silent)
  local old_object_name = self.object_name
  local props = self:file_info(self.file, silent)

  if update_relpath then
    self.relpath = props.relpath
  end
  self.object_name = props.object_name
  self.mode_bits = props.mode_bits
  self.has_conflicts = props.has_conflicts
  self.i_crlf = props.i_crlf
  self.w_crlf = props.w_crlf

  return old_object_name ~= self.object_name
end

--- @class Gitsigns.FileInfo
--- @field relpath string
--- @field i_crlf boolean
--- @field w_crlf boolean
--- @field mode_bits string
--- @field object_name string
--- @field has_conflicts true?

--- @param file string
--- @param silent? boolean
--- @return Gitsigns.FileInfo
function Obj:file_info(file, silent)
  local results, stderr = self:command({
    'dump', 'entry',
    file or self.file,
  }, { supress_stderr = true })

  local result = {}
  result.i_crlf = false
  result.w_crlf = false
  result.mode_bits = '100664'
  if stderr then
    result.relpath = stderr:gsub('^.*: ', '')
  else
    result.relpath = results[1]
  end

  result.object_name = git_command({ file }, { command = 'sha1sum' })[1]
  return result
end

--- @param revision string
--- @return string[] stdout, string? stderr
function Obj:get_show_text(revision)
  if not self.relpath then
    return {}
  end

  local stdout, stderr = self.repo:get_show_text(revision .. ':' .. self.relpath)

  if not self.i_crlf and self.w_crlf then
    for i = 1, #stdout do
      stdout[i] = stdout[i] .. '\r'
    end
  end

  return stdout, stderr
end

Obj.unstage_file = function(self)
  self:command({ 'reset', self.file })
end

--- @class Gitsigns.BlameInfo
--- -- Info in header
--- @field sha string
--- @field abbrev_sha string
--- @field orig_lnum integer
--- @field final_lnum integer
--- Porcelain fields
--- @field author string
--- @field author_mail string
--- @field author_time integer
--- @field author_tz string
--- @field committer string
--- @field committer_mail string
--- @field committer_time integer
--- @field committer_tz string
--- @field summary string
--- @field previous string
--- @field previous_filename string
--- @field previous_sha string
--- @field filename string

--- @param lines string[]
--- @param lnum integer
--- @param ignore_whitespace boolean
--- @return Gitsigns.BlameInfo?
function Obj:run_blame(lines, lnum, ignore_whitespace)
  local not_committed = {
    author = 'Not Committed Yet',
    ['author_mail'] = '<not.committed.yet>',
    committer = 'Not Committed Yet',
    ['committer_mail'] = '<not.committed.yet>',
  }

  if not self.object_name or self.repo.abbrev_head == '' then
    -- As we support attaching to untracked files we need to return something if
    -- the file isn't isn't tracked in git.
    -- If abbrev_head is empty, then assume the repo has no commits
    return not_committed
  end

  local args = {
    'blame',
    '--json',
    self.file,
  }

  if ignore_whitespace then
    args[#args + 1] = '-w'
  end

  --- type table?
  local results = self:command(args, { json = true })

  if results == nil or results.annotation == nil then
    return not_committed
  end

  local current_line = results.annotation[lnum]

  --- type table
  local current_commit = {}

  if current_line == nil or current_line.label == "unstaged" or current_line.label == 'staged' then
    return not_committed
  end

  for _, commit in ipairs(results.commits) do
    if commit.commit == current_line.commit then
      current_commit = commit
      break
    end
  end

  if next(current_commit) == nil then
    return not_committed
  end


  local function iso8601_to_timestamp(iso_date)
    local y, m, d, h, min, s, tz_hour, tz_min = string.match(iso_date,
      "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%+([%d+-]+):([%d+-]+)")
    local offset = (tonumber(tz_hour) * 3600) + (tonumber(tz_min) * 60)
    local timestamp = os.time({ year = y, month = m, day = d, hour = h, min = min, sec = s }) - offset

    return timestamp
  end

  local function first_non_empty_line(str)
    for line in str:gmatch("[^\r\n]+") do
        if line:match("^%s*(.-)%s*$") ~= "" then
            return line
        end
    end
    return ""
end


  --- @type Gitsigns.BlameInfo
  local ret = {}
  ret.sha = current_commit.commit
  ret.orig_lnum = current_line.line
  ret.filename = current_commit.path
  if current_commit.parents ~= nil and #current_commit.parents > 0 then
    ret.previous = 'previous'
    ret.previous_filename = current_commit.path
    ret.previous_sha = current_commit.parents[1]
  end
  ret.revision = current_commit.revision
  ret.abbrev_sha = string.sub(current_commit.commit, 1, 8)
  ret.author = current_line.author
  ret.author_mail = current_line.author
  ret.summary = first_non_empty_line(current_commit.message)
  ret.author_time = iso8601_to_timestamp(current_line.date)

  return ret
end

--- @param obj Gitsigns.GitObj
local function ensure_file_in_index(obj)
  if obj.object_name and not obj.has_conflicts then
    return
  end

  if not obj.object_name then
    -- If there is no object_name then it is not yet in the index so add it
    obj:command({ 'add', obj.file })
  end
  obj:update_file_info()
end

-- Stage 'lines' as the entire contents of the file
--- @param lines string[]
function Obj:stage_lines(lines)
  print('Arc not support stage_lines')
end

--- @param hunks Gitsigns.Hunk.Hunk
--- @param invert? boolean
function Obj.stage_hunks(self, hunks, invert)
  print('Arc not support stage_hunks')
end

--- @return string?
function Obj:has_moved()
  local out = self:command({ 'diff', '--name-status', '--cached' })
  local orig_relpath = self.orig_relpath or self.relpath
  for _, l in ipairs(out) do
    local parts = vim.split(l, '%s+')
    if #parts == 3 then
      local orig, new = parts[2], parts[3]
      if orig_relpath == orig then
        self.orig_relpath = orig_relpath
        self.relpath = new
        self.file = self.repo.toplevel .. '/' .. new
        return new
      end
    end
  end
end

--- @return string[] - @param sha string
function Obj:get_commit_body(sha)
  local ret = self:command({ 'show', '--git', '--name-only', sha })

  for i = #ret, 1, -1 do -- remove list modified files
        if ret[i]:match(".*/.*") then
            table.remove(ret, i)
        else
            break
        end
    end

  return ret
end

--- @param file string
--- @param encoding string
--- @param gitdir string?
--- @param toplevel string?
--- @return Gitsigns.GitObj?
function Obj.new(file, encoding, gitdir, toplevel)
  if in_arc_dir(file) then
    dprint('In arc dir')
    return nil
  end
  local self = setmetatable({}, { __index = Obj })

  self.file = file
  self.encoding = encoding
  self.repo = Repo.new(util.dirname(file), gitdir, toplevel)

  if not self.repo.gitdir then
    dprint('Not in arc repo')
    return nil
  end

  -- When passing gitdir and toplevel, suppress stderr when resolving the file
  local silent = gitdir ~= nil and toplevel ~= nil

  self:update_file_info(true, silent)

  return self
end

return M
