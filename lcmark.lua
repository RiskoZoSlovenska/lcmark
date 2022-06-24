local cmark = require("cmark")
local re = require("re")

local sp = re.compile(" [ \t] ")
local nl = re.compile(" ('\r\n') / ('\r') / ('\n') ")

local lcmark = {}

lcmark.version = "0.29.0"

lcmark.writers = {
  html = function(d, opts, _) return cmark.render_html(d, opts) end,
  man = cmark.render_man,
  xml = function(d, opts, _) return cmark.render_xml(d, opts) end,
  latex = cmark.render_latex,
  commonmark = cmark.render_commonmark
}

local default_yaml_parser = nil

local function try_load(module_name, func_name)
  if default_yaml_parser then -- already loaded; skip
    return
  end

  local success, loaded = pcall(require, module_name)

  if not success then
    return
  end
  if type(loaded) ~= "table" or type(loaded[func_name]) ~= "function" then
    return
  end

  default_yaml_parser = loaded[func_name]
  lcmark.yaml_parser_name = module_name .. "." .. func_name
end

try_load("lyaml", "load")
try_load("yaml", "load") -- must come before yaml.eval
try_load("yaml", "eval")

-- the reason yaml.load must come before yaml.eval is that the 'yaml' library
-- prints error messages if you try to index non-existent fields such as 'eval'


local function parse_options_table(opts)
  if type(opts) == 'table' then
    return (cmark.OPT_VALIDATE_UTF8 + cmark.OPT_NORMALIZE +
      (opts.smart and cmark.OPT_SMART or 0) +
      (opts.safe and 0 or cmark.OPT_UNSAFE) +
      (opts.hardbreaks and cmark.OPT_HARDBREAKS or 0) +
      (opts.sourcepos and cmark.OPT_SOURCEPOS or 0)
      )
  else
     return opts
  end
end

-- walk nodes of table, applying a callback to each
local function walk_table(table, callback, inplace)
  assert(type(table) == 'table')
  local new = {}
  local res
  for k, v in pairs(table) do
    if type(v) == 'table' then
      res = walk_table(v, callback, inplace)
    else
      res = callback(v)
    end
    if not inplace then
      new[k] = res
    end
  end
  if not inplace then
    return new
  end
end

-- We inject cmark into environment where filters are
-- run, so users don't need to qualify each function with 'cmark.'.
local defaultEnv = setmetatable({}, { __index = _G })
for k,v in pairs(cmark) do
  defaultEnv[k] = v
end

local loadfile_with_env
if setfenv then
  -- Lua 5.1/LuaJIT
  loadfile_with_env = function(filename)
    local result, msg = loadfile(filename)
    if result then
      return setfenv(result, defaultEnv)
    else
      return result, msg
    end
  end
else
  -- Lua 5.2+
  loadfile_with_env = function(filename)
    return loadfile(filename, 't', defaultEnv)
  end
end

-- Loads a filter from a Lua file and populates the loaded function's
-- environment with all the fields from `cmark-lua`.
-- Returns the filter function on success, or `nil, msg` on failure.
function lcmark.load_filter(filename)
  local result, msg = loadfile_with_env(filename)
  if result then
    local evaluated = result()
    if type(evaluated) == 'function' then
        return evaluated
    else
        return nil, string.format("filter %s returns a %s, not a function",
                                  filename, type(evaluated))
    end
  else
    return nil, msg
  end
end

-- Render a metadata node in the target format.
local function render_metadata(node, writer, options, columns)
  local firstblock = cmark.node_first_child(node)
  if cmark.node_get_type(firstblock) == cmark.NODE_PARAGRAPH and
     not cmark.node_next(firstblock) then
     -- render as inlines
     local ils = cmark.node_new(cmark.NODE_CUSTOM_INLINE)
     local b = cmark.node_first_child(firstblock)
     while b do
        local nextb = cmark.node_next(b)
        cmark.node_append_child(ils, b)
        b = nextb
     end
     local result = string.gsub(writer(ils, options, columns), "%s*$", "")
     cmark.node_free(ils)
     return result
  else -- render as blocks
     return writer(node, options, columns)
  end
end

-- Iterate over the metadata, converting to cmark nodes.
-- Returns a new table.
local function convert_metadata_strings(table, options)
  return walk_table(table,
                    function(s)
                      if type(s) == "string" then
                        return cmark.parse_string(s, options)
                      elseif type(s) == "userdata" then
                        return tostring(s)
                      else
                        return s
                      end
                    end, false)
end

local yaml_block = re.compile([[
  Block <- Begin (Content+ / %sp) End
  Begin <- "---" Eol
  Content <- !End (!Eol .)* Eol
  End <- ("---" / "...") Eol
  Eol <- %sp* %nl
]], { sp = sp, nl = nl })

-- Parses document with optional front YAML metadata; returns document,
-- metadata.
local function parse_document_with_metadata(inp, parser, options)
  local metadata = {}
  local meta_end = re.match(inp, yaml_block)
  if meta_end then
    if meta_end then
      local ok, yaml_meta, err = pcall(parser, string.sub(inp, 1, meta_end))
      if not ok then
        return nil, yaml_meta -- the error message
      elseif not yaml_meta then -- parser may return nil, err instead of error
        return nil, tostring(err)
      end
      if type(yaml_meta) == 'table' then
        metadata = convert_metadata_strings(yaml_meta, options)
        if type(metadata) ~= 'table' then
          metadata = {}
        end
        -- We insert blank lines where the header was, so sourcepos is accurate:
        inp = string.gsub(string.sub(inp, 1, meta_end), '[^\n\r]+', '') ..
           string.sub(inp, meta_end)
      end
    end
  end
  local doc = cmark.parse_string(inp, options)
  return doc, metadata
end

-- Apply a compiled template to a context (a dictionary-like
-- table).
function lcmark.apply_template(m, ctx)
  if type(m) == 'function' then
    return m(ctx)
  elseif type(m) == 'table' then
    local buffer = {}
    for i,v in ipairs(m) do
      buffer[i] = lcmark.apply_template(v, ctx)
    end
    return table.concat(buffer)
  else
    return tostring(m)
  end
end

local function get_value(ref, ctx)
  local result = ctx
  assert(type(ref) == 'table')
  for _,varpart in ipairs(ref) do
    if type(result) ~= 'table' then
      return nil
    end
    result = result[varpart]
    if result == nil then
      return nil
    end
  end
  return result
end

local function set_value(ref, newval, ctx)
  local result = ctx
  assert(type(ref) == 'table')
  for i,varpart in ipairs(ref) do
    if i == #ref then
      -- last one
      result[varpart] = newval
    else
      result = result[varpart]
      if result == nil then
        break
      end
    end
  end
end

local function is_truthy(val)
  local is_empty_tbl = type(val) == "table" and #val == 0
  return val and not is_empty_tbl
end

-- if s starts with newline, remove initial and final newline
local function trim(s)
  if s:match("^[\r\n]") then
    return s:gsub("^[\r]?[\n]?", ""):gsub("[\r]?[\n]?$", "")
  else
    return s
  end
end

local function conditional(ref, ifpart, elsepart)
  return function(ctx)
    local result
    if is_truthy(get_value(ref, ctx)) then
      result = lcmark.apply_template(ifpart, ctx)
    elseif elsepart then
      result = lcmark.apply_template(elsepart, ctx)
    else
      result = ""
    end
    return trim(result)
  end
end

local function forloop(ref, inner, sep)
  return function(ctx)
    local val = get_value(ref, ctx)
    if not is_truthy(val) then
      return ""
    end
    if type(val) ~= 'table' then
      val = {val} -- if not a table, just iterate once
    end
    local buffer = {}
    for i,elem in ipairs(val) do
      set_value(ref, elem, ctx) -- set temporary context
      buffer[#buffer + 1] = lcmark.apply_template(inner, ctx)
      if sep and i < #val then
        buffer[#buffer + 1] = lcmark.apply_template(sep, ctx)
      end
      set_value(ref, val, ctx) -- restore original context
    end
    local result = lcmark.apply_template(buffer, ctx)
    return trim(result)
  end
end

local function variable(ref)
  return function(ctx)
    local val = get_value(ref, ctx)
    if is_truthy(val) then
      return tostring(val)
    else
      return ""
    end
  end
end

local TemplateGrammar = re.compile([[
  Main <- Template (!. / {})
  Template <- {| (
                (ConditionalNl / Conditional) -> conditional /
                (ForLoopNl / ForLoop) -> forloop /
                Variable -> variable /
                EscapedDollar /
                Any
              )* |}

  -- The Nl forms eat an extra newline after the end, but only if the opening
  -- if() or for() ends with a newline (which is also consumed).  This is to
  -- avoid excess blank space when a document contains many ifs or fors that
  -- evaluate to false.

  ConditionalNl <- "$if(" Reference ")$" %nl Template ("$else$" Template)?
                    "$endif$" %nl
  Conditional   <- "$if(" Reference ")$"     Template ("$else$" Template)?
                    "$endif$"

  ForLoopNl <- "$for(" Reference ")$" %nl Template ("$sep$" Template)?
                "$endfor$" %nl
  ForLoop   <- "$for(" Reference ")$"     Template ("$sep$" Template)?
                "$endfor$"

  Variable <- "$" !(Reserved "$") Reference "$"

  Reference <- {| Name ("." Name)* |}
  Name <- { [a-zA-Z0-9_-]+ }
  Reserved <- "if" / "endif" / "else" / "for" / "endfor" / "sep"

  EscapedDollar <- "$$" -> "$"
  Any <- { [^$]+ }
]], {
  conditional = conditional,
  forloop = forloop,
  variable = variable,
  nl = nl,
})

-- Compiles a template string into an  arbitrary template object
-- which can then be passed to `lcmark.apply_template()`.
-- Returns the template object on success, or `nil, msg` on failure.
function lcmark.compile_template(template_str)
  local compiled, fail_pos = re.match(template_str, TemplateGrammar)

  if fail_pos then
    local _, line_num = template_str:sub(1, fail_pos):gsub('[^\n\r]+', '')
    return nil, string.format("parse failure on line %d near '%s'", line_num,
                              template_str:sub(fail_pos, fail_pos + 40)
                             )
  elseif not compiled then
    return nil, "parse failure at the end of the template"
  else
    return compiled, nil
  end
end

-- Compiles and applies a template string to a context table.
-- Returns the  resulting document string on success, or
-- `nil, msg` on failure.
function lcmark.render_template(tpl, ctx)
  local compiled_template, msg = lcmark.compile_template(tpl)
  if not compiled_template then
    return nil, msg
  end
  return lcmark.apply_template(compiled_template, ctx)
end

-- Converts `inp` (a CommonMark formatted string) to the output
-- format specified by `to` (a string; one of `html`, `commonmark`,
-- `latex`, `man`, or `xml`).  `options` is a table with the
-- following fields (all optional):
-- * `smart` - enable "smart punctuation"
-- * `hardbreaks` - treat newlines as hard breaks
-- * `safe` - filter out potentially unsafe HTML and links
-- * `sourcepos` - include source position in HTML and XML output
-- * `filters` - an array of filters to run (see `load_filter` above)
-- * `columns` - column width, or 0 to preserve wrapping in input
-- * `yaml_metadata` - whether to parse initial YAML metadata block
-- * `yaml_parser` - a function to parse YAML with (see
--    [YAML Metadata](#yaml-metadata))
-- Returns `body`, `meta` on success, where `body` is the rendered
-- document body and `meta` is the YAML metadata as a table. If the
-- `yaml_metadata` option is false or if the document contains no
-- YAML metadata, `meta` will be an empty table. In case of an
-- error, the function returns `nil, nil, msg`.
function lcmark.convert(inp, to, options)
  local writer = lcmark.writers[to]
  if not writer then
    return nil, nil, ("unknown output format '" .. tostring(to) .. "'")
  end
  local opts, columns, filters, yaml_metadata, yaml_parser
  if options then
     opts = parse_options_table(options)
     columns = options.columns or 0
     filters = options.filters or {}
     yaml_metadata = options.yaml_metadata
     yaml_parser = options.yaml_parser or default_yaml_parser
  else
     opts = cmark.OPT_DEFAULT
     columns = 0
     filters = {}
     yaml_metadata = false
     yaml_parser = default_yaml_parser
  end
  if not yaml_parser then
    error("no YAML libraries were found and no yaml_parser was specified")
  end
  local doc, meta
  if yaml_metadata then
    doc, meta = parse_document_with_metadata(inp, yaml_parser, opts)
    if not doc then
      return nil, nil, ("YAML parsing error:\n" .. meta)
    end
  else
    doc = cmark.parse_string(inp, opts)
    meta = {}
  end
  if not doc then
    return nil, nil, "unable to parse document"
  end
  for _, f in ipairs(filters) do
    -- do we want filters to apply automatically to metadata?
    -- better to let users do this manually when they want to.
    -- walk_table(meta, function(node) f(node, meta, to) end, true)
    local ok, msg = pcall(function() f(doc, meta, to) end)
    if not ok then
      return nil, nil, ("error running filter:\n" .. msg)
    end
  end
  local body = writer(doc, opts, columns)
  local data = walk_table(meta,
                          function(node)
                            if type(node) == "userdata" then
                              return render_metadata(node, writer, opts, columns)
                            else
                              return node
                            end
                          end, false)
  -- free memory allocated by libcmark
  cmark.node_free(doc)
  walk_table(meta,
             function(node)
               if type(node) == "userdata" then
                 cmark.node_free(node)
               end
             end, true)
  return body, data
end

return lcmark
