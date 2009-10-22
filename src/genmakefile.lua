#! /usr/bin/env lua

local do_nothing = function() end

local spam = function(...)
  io.stderr:write("spam:\t", table.concat({...}, ' '), '\n')
  io.flush()
end
--spam = do_nothing

local log_warning = function(...)
  io.stderr:write("warn:\t", table.concat({...}, ' '), '\n')
  io.flush()
end

local log_error = function(...)
  io.stderr:write("error:\t", table.concat({...}, ' '), '\n')
  io.flush()
end

local make_accum = function(sep)
  local buf = {}
  local cat = function(v)
    buf[#buf + 1] = tostring(v)
  end
  local concat = function()
    return table.concat(buf, sep or "")
  end
  return cat, concat
end

local load_table = function(str, chunkname)
  --spam("load_table", showstr(chunkname), showstr(str))

  local fn, err = loadstring("return {"..str.."}", chunkname)

  if not fn then
    log_error("load_table error:", err)
    log_error("===== begin source dump =====")
    log_error("return {"..str.."}")
    log_error("===== end source dump =====")
    return nil
  end

  setfenv(fn, {})
  local status, t = pcall(fn)
  if not status then
    log_error("load_table error:", t)
    log_error("===== begin source dump =====")
    log_error("return {"..str.."}")
    log_error("===== end source dump =====")
    return nil
  end

  return t
end

-- TODO: Bad. Must allow nested ":" on the left!
local parsearg2 = function(str)
  return str:match("([^:]*):?(.*)")
end

-- TODO: Bad. Must allow nested ":" on the left and the middle!
local parsearg3 = function(str)
  return str:match("([^:]*):([^:]*):?(.*)")
end

-- TODO: Bad. Must allow nested ":" on the left and the middle!
local parsearg4 = function(str)
  return str:match("([^:]*):([^:]*):([^:]*):?(.*)")
end

local showstr = function(str, maxlen)
  maxlen = maxlen or 20
  len = #str
  return
    '"'
    .. (
      (
        len > maxlen and (str:sub(1, maxlen - 3) .. "...") or str
      ):gsub("\n", "\\n")
    )
    .. '"'
end

-- Note original dictionary is changed inplace, not cloned
local wrap_dictionary = function(parent, dictionary)
  return setmetatable(dictionary, {__index = parent})
end

-- Removes all leading newlines
-- Leaves at most two newlines elsewhere
local compactnl = function(str)
  return (str:gsub("^\n\n+", ""):gsub("\n\n\n+", "\n\n"))
end

local mt = {}

-- Private functions

local getvalue = function(self, name, args)
  if name then
    local v = self[name]
    local tv = type(v)
    if tv == "function" then
      --spam("call", showstr(name), args and showstr(args))

      return v(self, args)
    elseif tv == "table" then
      --spam("get", showstr(name), args and showstr(args))

      if args ~= nil then
        v = v[args]
      end

      return v
    elseif tv ~= "nil" then
      --spam("raw", showstr(name), args and showstr(args))

      return v
    end
  end
  log_warning("get missed", showstr(name)) -- more like notice actually
  return nil
end

local getstr = function(self, name, args)
  local value = getvalue(self, name, args)
  local tv = type(value)
  if tv == "string" or tv == "number" or tv == "boolean" then
    return tostring(value)
  end
  return nil
end

local resolve_name = function(self, name)
  if name:sub(1, 1) == "@" then
    return self:fill(name)
  end

  return getstr(self, name, nil)
end

-- TODO: Too inflexible!
local mkdep = function(self, cflags, path)
  -- Assuming dependencies in the code do not change
  -- when laguage is overridden (c++ instead c)

  local objprefix = "@{objprefix}" -- TODO: Make configurable

  if path:sub(-1, -1) ~= "/" then
    path = path .. "/"
  end

  local objects = {}
  local template = {}

  local input = assert(io.popen("ls "..path.."*.c"))
  for cfile in input:lines() do
    local basename = cfile:sub(#path + 1, #cfile):sub(1, -3)
    local objname = objprefix .. basename .. ".o"

    -- TODO: Should probably pass CFLAGS here.
    local gccin = assert(
        io.popen("gcc "..cflags.." -MM -MG -MT '"..objname.."' '"..cfile.."'")
      )

    -- Note cflags argument is ignored, it is used for -MM invocation only.
    template[#template + 1] = gccin:read("*a")
      .. "\t@{CC} $(CFLAGS) @{cflags} -o $@ -c " .. cfile .."\n"

    objects[#objects + 1] = objname
  end

  return table.concat(objects, " "), table.concat(template, "\n")
end

-- Public functions

mt["--"] = function()
  -- That was a comment. Ignoring
  return ""
end

-- Note format is a run-time-only argument.
mt["fill"] = function(self, template, format)
  -- TODO: Cache derived formats
  format = format or "@{}"
  if type(format) ~= "string" or #format ~= 3 then
    log_error("fill: bad format", template, format)
    return nil
  end

  local gsubfmt = format:sub(1, 1):gsub("%%", "%%%%")
    .."(%b" .. format:sub(2, 3) .. ")"
  local matchfmt = "^"..format:sub(2, 2).."([^:]*):?(.*)"..format:sub(3, 3).."$"

  if template then
    return (template:gsub(
        gsubfmt,
        function(str)
          local name, args = str:match(matchfmt)
          --spam("fill", showstr(name), showstr(args))
          return getstr(self, name, args)
        end
      ))
  else
    log_error("fill: bad template")
  end
end

mt["fill-template"] = function(self, arg)
  local name, table_template = parsearg2(arg)

  if name and table_template then
    local dictionary = load_table(
        self:fill(table_template),
        "@fill-template/"..name
      )

    if dictionary then
      local value = resolve_name(self, name)
      if value then
        --spam("fill-template", showstr(name), showstr(table_template, 30))
        return wrap_dictionary(self, dictionary):fill(value)
      else
        log_error("fill-template: bad value")
      end
    else
      log_error("fill-template: bad dictionary")
    end
  else
    log_error("fill-template: bad arguments")
  end
end

mt["lua-escape"] = function(self, arg)
  if arg then
    return ("%q"):format(self:fill(arg))
  end

  log_error("lua-escape failed")
end

mt["define"] = function(self, arg)
  local name, str = parsearg2(arg)

  -- Note name is not resolved
  if name and str then
    --spam("define", showstr(name), showstr(arg))
    self[name] = str
    return ""
  end

  log_error("define failed")
end

mt["define-fill"] = function(self, arg)
  local name, template = parsearg2(arg)

  -- Note name is not resolved
  if name and template then
    self[name] = self:fill(template)
    --spam("define-fill", showstr(name), showstr(self[name]))
    return ""
  end

  log_error("define-fill failed")
end

mt["define-table"] = function(self, arg)
  local name, template = parsearg2(arg)

  -- Note name is not resolved
  if name and template then
    template = self:fill(template)
    --spam("define-table", showstr(name), showstr(template, 30))
    self[name] = load_table(template, "@define-table/"..name)
    return ""
  end

  log_error("define-table failed")
end

mt["fill-macro"] = function(self, arg)
  local name, format, template = parsearg3(arg)
  if name and format and template then
    local dict = load_table(self:fill(template), "@fill-macro/"..name)
    if dict then
      dict = wrap_dictionary(
          mt, -- Note new dictionary is intentionally not derived from self
          dict
        )
      local value = resolve_name(self, name)
      if value then
        return self:fill(dict:fill(value, format))
      else
        log_error("fill-macro: bad value", showstr(name))
      end
    else
      log_error("fill-macro: bad dict")
    end
  else
    log_error("fill-macro: bad args")
  end
end

mt["map-template"] = function(self, arg)
  local mapname, templatename = parsearg2(arg)
  if mapname and templatename then
    local cat, concat = make_accum()
    local mapvalue = getvalue(self, mapname, nil)
    local template = resolve_name(self, templatename)
    if template == nil then
      template = templatename
    end

    if type(mapvalue) == "table" and template then
      --spam("map-template:", showstr(mapname), #mapvalue)
      for i, dict in ipairs(mapvalue) do
        -- TODO: Cache wrapped dictionaries
        cat (wrap_dictionary(self, dict):fill(template))
      end
      return concat()
    end
  end
  log_error("map-template failed")
end

mt["define-dep"] = function(self, arg)
  local name_objects, name_template, cflags, template = parsearg4(arg)
  if name_objects and name_template and cflags and template then
    -- Note names are not resolved

    cflags = self:fill(cflags)
    local path = self:fill(template)

    local value_objects, value_template = mkdep(self, cflags, path)

    self[name_objects] = value_objects
    self[name_template] = value_template

    return ""
  end
  log_error("define-dep failed")
end

mt["append"] = function(self, arg)
  local name, value = parsearg2(arg)
  if name and value then
    local old_value = getstr(self, name, nil) or ""
    self[name] = old_value .. (self:fill(value) or "")

    return ""
  else
    log_error("append failed")
  end
end

mt["insert"] = function(self, arg)
  local name, value = parsearg2(arg)
  if name and value then
    local old_value = getvalue(self, name, nil)
    if type(old_value) ~= "table" then
      old_value = { old_value }
    end
    old_value[#old_value + 1] = (self:fill(value) or "")
    self[name] = old_value

    return ""
  else
    log_error("insert failed")
  end
end

mt["concat"] = function(self, arg)
  local name, separator = parsearg2(arg)
  if name and separator then
    local value = getvalue(self, name, nil)
    if type(value) == "table" then
      return table.concat(value, separator)
    elseif tv == "string" or tv == "number" or tv == "boolean" then
      return tostring(value)
    else
      log_error("concat: bad table")
    end
  else
    log_error("concat failed")
  end
end

local dictionary = wrap_dictionary(mt, {})

io.write(
    compactnl(dictionary:fill(io.read("*a")))
  )
io.flush()
