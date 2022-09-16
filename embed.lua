local bit = require("bit")
local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
int truct__is_optimized(void);
uint64_t truct__get_file_write_time(const char* filename);
uint32_t truct__hash_file(const char* filename);
void truct__embed_file(const char* input, const char* output);
]]

build = {}

-- default to nothing
if compile_dir == nil then
    compile_dir = ""
end

config = {
    ["os"] = ffi.os,
    ["opt"] = (C.truct__is_optimized() ~= 0)
}

-- disable buffering
io.stdout:setvbuf("no")

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

function string.starts(str, start)
   return string.sub(str, 1, string.len(start)) == start
end

function ends_with(str, ending)
   return ending == "" or str:sub(-#ending) == ending
end

function get_file_name(file)
    local s = file:match("^.+/(.+)$")
    if s == nil then return file else return s end
end

function build.get_directory(file)
    return file:match("^(.+/).+$")
end

function cc_cmd(input, cflags)
    local output = get_file_name(input)
    local cmd = "clang -MMD -MF bin/"..output..".d "..input.." "..cflags.." -c -o bin/"..output..".o 2>&1"
    if compile_dir ~= "" then
       cmd = "cd "..compile_dir.." && "..cmd
    end
    
    return io.popen(cmd)
end

function resolve_path(P)
    local function at(s,i)
        return string.sub(s,i,i)
    end

    -- Split path into anchor and relative path.
    local anchor = ''
    
    -- According to POSIX, in path start '//' and '/' are distinct,
    -- but '///+' is equivalent to '/'.
    if P:match '^//' and at(P, 3) ~= '/' then 
        anchor = '//'
        P = P:sub(3)
    elseif at(P, 1) == '/' then
        anchor = '/'
        P = P:match '^/*(.*)$'
    end
        
    local parts = {}
    for part in P:gmatch('[^/]+') do
        if part == '..' then
            if #parts ~= 0 and parts[#parts] ~= '..' then
                table.remove(parts)
            else
                table.insert(parts, part)
            end
        elseif part ~= '.' then
            table.insert(parts, part)
        end
    end
    P = anchor..table.concat(parts, '/')
    if P == '' then P = '.' end
    return P
end

function simple_table_match(a, b)
    for k,v in pairs(a) do
        if v ~= b[k] then
            return false
        end
    end

    return true
end

function serialize(file, o, depth)
    if type(o) == "string" then
        file:write(string.format("%q", o))
    elseif type(o) == "table" then
        file:write("{\n")
        for k,v in pairs(o) do
            -- print indent
            for i=0,depth do file:write("  ") end
            
            file:write("[")
            serialize(file, k, 0)
            file:write("] = ")
            serialize(file, v, depth + 1)
            file:write(",\n")
        end
        
        -- print indent
        for i=1,depth do file:write("  ") end
        file:write("}")
    else
        file:write(tostring(o))
    end
end

function add_database(database, input)
    -- print(input..": first time")
    real_path = compile_dir..input

    local hash = C.truct__hash_file(real_path)
    local last_write = tostring(C.truct__get_file_write_time(real_path))

    database[input] = { ["hash"] = hash, ["last_write"] = last_write, ["deps"] = {}, ["changed"] = true }
end

function get_deps_from_dfile(input)
    local dep_path = compile_dir.."bin/"..get_file_name(input)..".d"
    local f = io.open(dep_path, "rb")
    if (f == nil) then
        print("build warning: could not build dependency file for "..input)
        return nil
    end

    local str = f:read("*a")
    out, ins = str:match("([^:]+):([^:]+)")
    -- remove the backslash-newlines
    ins = ins:gsub("\\\r\n", "")
    -- simplify the slashes
    ins = ins:gsub("\\", "/")
    
    -- we keep track of it just for the sake
    changes = false
    deps = {}

    for s in string.gmatch(ins, "%S+") do
        if s ~= input then
            table.insert(deps, resolve_path(s))
        end
    end

    f:close()
    return deps
end

function expand_paths(files)
    new_files = {}
    for i,f in ipairs(files) do
        if ends_with(f, "/") then
            -- read files in directory
            if ffi.os == "Windows" then
                local proc = io.popen("dir /B "..(compile_dir..f):gsub("/", "\\"))

                for l in proc:lines() do
                    if ends_with(l, ".c") then
                        local path = string.gsub(f..l, "\\", "/")
                        table.insert(new_files, path)
                    end
                end

                proc:close()
            else
                local proc = io.popen("find "..compile_dir..f.."*.c -maxdepth 0")

                for l in proc:lines() do
                    table.insert(new_files, f..get_file_name(l))
                end

                proc:close()
            end
        else
            table.insert(new_files, f)
        end
    end

    return new_files
end

function has_file_changed(database, input)
    -- we need to at least have it in the database
    local old = database[input]
    if old == nil then
        -- add to database
        add_database(database, input)
        return true
    end
    
    if old.changed then
        return true
    end
    
    -- check dependencies
    for k,v in pairs(old.deps) do
        if has_file_changed(database, v) then
            -- print(input..": dependency changed ("..v..")")
            old.changed = true
            return true
        end
    end
    
    -- Check if it's filetime changed
    local last_write = tostring(C.truct__get_file_write_time(compile_dir..input))
    if last_write == old.last_write then
        -- print(input..": file time didn't changed ("..last_write.." | "..old.last_write..")")
        return false
    else
        old.last_write = last_write
    end
    
    -- Check input file
    local hash = C.truct__hash_file(compile_dir..input)
    if hash ~= old.hash then
        -- print(input..": hash changed ("..hash.." | "..old.hash..")")
        old.hash = hash
        old.changed = true
        return true
    end
    
    return false
end

function build.build_lua(directory)
    local dep = loadfile(directory.."/build.lua")
    assert(dep)
    
    local old = compile_dir
    compile_dir = (directory.."/"):gsub("\\", "/")
    local changes = dep()
    compile_dir = old
    
    if changes == nil then
        print("Failed to compile "..directory)
        os.exit(1)
    end
    
    return changes
end

function build.compile(cache_file, file_patterns, cflags)
    -- fixup any directory queries
    files = expand_paths(file_patterns)
    
    local database = {}
    
    -- Try to load from cache
    local cache = loadfile(compile_dir..cache_file)
    if cache ~= nil then
        print("Loading from the cache...")
        local result = cache()
        
        -- Diff the config (if it changed we don't use the old database)
        local new_config = result.config
        if not simple_table_match(config, new_config) then
            print("Configuration changed!")
        else
            database = result.database
        end
    end

    -- check for changes
    local changed_files = {}
    local changed_files_count = 0
    
    for i,f in ipairs(files) do
        if has_file_changed(database, f) then
            -- we changed the file so we need to recompile it
            table.insert(changed_files, f)
            changed_files_count = changed_files_count + 1
        end
    end
    
    -- compile C files
    local handles = {}
    for i,f in ipairs(changed_files) do
        handles[i] = cc_cmd(f, cflags)
    end

    local progress = 1
    local has_errors = false
    for i,f in ipairs(changed_files) do
        local handle = handles[i]
        local str = handle:read("*a")
        
        print("["..progress.."/"..changed_files_count.."]  "..f)
        if str:len() ~= 0 then
            print(str)

            -- if the compile fails then remove from the database
            database[f] = nil
            has_errors = true
        end

        handle:close()
        progress = progress + 1
    end
    
    for i,f in ipairs(changed_files) do
        local d = database[f]
        
        if d ~= nil then
            local deps = get_deps_from_dfile(f)
            d.deps = deps
            
            for k,input in pairs(deps) do
                if database[input] == nil then
                    add_database(database, input)
                end
            end
        end
    end
    
    -- write new database
    database_file = io.open(compile_dir..cache_file, "wb")
    
    -- write out build options
    -- clear changed field from database entries
    for input,entry in pairs(database) do
        entry.changed = false
    end
    
    database_file:write("return {\n [\"config\"] = ")
    serialize(database_file, config, 1)
    database_file:write(",\n")
    
    database_file:write("  [\"database\"] = ")
    serialize(database_file, database, 1)
    database_file:write("\n}\n")
    
    --[[ for input,entry in pairs(database) do
        local hash_str = string.format("%08x", database[input].hash)
        database_file:write(entry.last_write.."|"..input..": 0x"..hash_str.." ")

        for k,v in ipairs(entry.deps) do
            database_file:write(v.." ")
        end

        database_file:write("\n")
    end ]]--
    database_file:close()
    
    if has_errors then
        print("Exited with errors!")
        return nil
    end
    
    -- generate list of outputs
    local outputs = {}
    for i,f in ipairs(files) do
        table.insert(outputs, "bin/"..get_file_name(f)..".o")
    end
    
    local changed = next(changed_files) ~= nil
    return outputs, changed
end

function build.command(cmd)
    if compile_dir ~= "" then
        cmd = "cd "..compile_dir.." && "..cmd
    end
    
    print(cmd)
    os.execute(cmd)
end

function build.link(output, flags, objs)
    print("~~ LINK "..output.." ~~");
    
    local input_str = ""
    for i,f in ipairs(objs) do
        input_str = input_str.." "..f
    end
    
    local cmd = "clang "..input_str.." "..flags.." -o "..output
    build.command(cmd)
end

function build.lib(output, deps, objs)
    print("~~ LIB "..output.." ~~")

    local input_str = deps.." "
    for i,f in ipairs(objs) do
        input_str = input_str.." "..f
    end

    -- Archiver
    local cmd = ""
    if ffi.os == "Windows" then
        cmd = cmd.."lib /nologo /out:"..output.." "..input_str
    else
        cmd = cmd.."ar -rcs "..output.." "..input_str
    end

    build.command(cmd)
end
