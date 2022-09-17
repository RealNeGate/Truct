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

if ffi.os == "Windows" then
    config.exe_ext = ".exe"
    config.dll_ext = ".dll"
    config.lib_ext = ".lib"
else
    config.exe_ext = ""
    config.dll_ext = ".so"
    config.lib_ext = ".a"
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

function get_directory(file)
    local s = file:match("^(.+/).+$")
    if s == nil then return "" else return s end
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

function add_database(input, command)
    -- print(input..": first time")
    real_path = compile_dir..input

    local hash = C.truct__hash_file(real_path)
    local last_write = tostring(C.truct__get_file_write_time(real_path))

    build.database[input] = { ["mark"] = true, ["hash"] = hash, ["command"] = command, ["last_write"] = last_write, ["deps"] = {}, ["changed"] = true }
end

function get_deps_from_dfile(self, input)
    local dep_path = compile_dir..input
    local f = io.open(dep_path, "rb")
    if f == nil then
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
        if s ~= self then
            table.insert(deps, resolve_path(s))
        end
    end

    f:close()
    return deps
end

function expand_paths(files)
    new_files = {}
    for i,f in ipairs(files) do
        -- read files in directory
        local pattern = get_file_name(f).."$"
        pattern = pattern:gsub("%.", "%%.")
        pattern = pattern:gsub("%*", ".*")
        -- print(f.." -> "..pattern)

        if ffi.os == "Windows" then
            local dir = string.gsub(get_directory(compile_dir..f), "/", "\\")

            local proc = io.popen("dir /B "..dir)
            for l in proc:lines() do
                if string.match(l, pattern) then
                    local path = string.gsub(dir..l, "\\", "/")
                    table.insert(new_files, path)
                end
            end

            proc:close()
        else
            local proc = io.popen("find "..get_directory(compile_dir..f).." -maxdepth 0")

            for l in proc:lines() do
                if string.match(l, pattern) then
                    table.insert(new_files, dir..l)
                end
            end

            proc:close()
        end
    end

    return new_files
end

function has_file_changed(input, command)
    -- we need to at least have it in the database
    local old = build.database[input]
    if old == nil then
        -- add to database
        add_database(input, command)
        return true
    end

    old.mark = true
    if old.changed then
        return true
    end

    if command ~= nil and old.command ~= command then
        old.changed = true
        return true
    end

    -- check dependencies
    for k,v in pairs(old.deps) do
        if has_file_changed(v, nil) then
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

build.database = {}

-- stores what intermediate files map to what source files
intermediate_database = {}

-- Try to load from cache
local cache = loadfile("my.cache")
if cache ~= nil then
    print("Loading from the cache...")
    local result = cache()

    -- Diff the config (if it changed we don't use the old database)
    local new_config = result.config
    if not simple_table_match(config, new_config) then
        print("Configuration changed!")
    else
        build.database = result.database
    end
end

function command_with_cd(cmd)
    if compile_dir ~= "" then
        return "cd "..compile_dir.." && "..cmd
    else
        return cmd
    end
end

function build.command(cmd)
    os.execute(command_with_cd(cmd))
end

function build.del(path)
    if ffi.os == "Windows" then
        os.execute(command_with_cd("del "..path:gsub("/", "\\")))
    else
        os.execute(command_with_cd("rm "..path))
    end
end

function build.mkdir(path)
    if ffi.os == "Windows" then
        os.execute(command_with_cd("if not exist \""..path.."\" mkdir "..path))
    else
        os.execute(command_with_cd("mkdir -p "..path))
    end
end

function build.format(str, filepath)
    -- print(debug.traceback())
    return str:gsub("%%f", filepath):gsub("%%F", get_file_name(filepath))
end

-- runs the separate inputs on different processes
function build.foreach_chain(inputs, command, output_pattern)
    -- fixup any directory queries
    local resolved_inputs = expand_paths(inputs)

    -- check for changes
    local changed_files = {}
    local changed_files_count = 0

    local commands = {}
    local cc_files = {}
    local outputs = {}
    for i,f in ipairs(resolved_inputs) do
        local cmd = build.format(command, f)
        local output = build.format(output_pattern, f)

        if has_file_changed(f, cmd) then
            -- if it's a CC command we can use -MMD
            if cmd:starts("cc") or cmd:starts("clang") or cmd:starts("gcc") then
                cmd = cmd.." -MMD -MF "..output..".d"
                table.insert(cc_files, f)
            end

            commands[f] = { ["cmd"] = cmd, ["handle"] = io.popen(command_with_cd(cmd).." 2>&1"), ["output"] = output }

            -- we changed the file so we need to recompile it
            table.insert(changed_files, f)
            changed_files_count = changed_files_count + 1
        end

        table.insert(outputs, output)
        intermediate_database[output] = f
    end

    local progress = 1
    local has_errors = false
    for i,f in ipairs(changed_files) do
        local handle = commands[f].handle
        local str = handle:read("*a")

        print("["..progress.."/"..changed_files_count.."]  "..commands[f].cmd)
        if str:len() ~= 0 then
            print(str)

            -- if the compile fails then remove from the database
            build.database[f] = nil
            has_errors = true
        end

        if not handle:close() then
            print("Exited with errors!")
            os.exit(1)
        end
        progress = progress + 1
    end

    -- update depedencies on C files
    for i,f in ipairs(cc_files) do
        local d = build.database[f]

        if d ~= nil then
            local deps = get_deps_from_dfile(f, commands[f].output..".d")

            if deps == nil then
                -- remove from database if we can't resolve it
                build.database[f] = nil
            else
                d.deps = deps
                for k,input in pairs(deps) do
                    if build.database[input] == nil then
                        add_database(input, commands[f].cmd)
                    end
                end
            end
        end
    end

    return outputs
end

function build.chain(inputs, command, output)
    -- fixup any directory queries
    local resolved_inputs = expand_paths(inputs)
    local input_str = table.concat(resolved_inputs, ' ')
    local cmd = command:gsub("%%i", input_str):gsub("%%o", output)

    -- find real files in the database to do the dependencies on
    local source_inputs = {}
    for i,f in ipairs(resolved_inputs) do
        local g = f
        while intermediate_database[g] ~= nil do
            g = intermediate_database[g]
        end

        table.insert(source_inputs, g)
    end

    -- check for changes
    local changes = false
    local d = build.database[output]

    if d == nil then
        build.database[output] = { ["mark"] = true, ["hash"] = 0, ["command"] = cmd, ["last_write"] = 0, ["deps"] = source_inputs, ["changed"] = true }
        changes = true
    else
        d.mark = true

        if d.command ~= cmd then
            changes = true
        else
            for i,f in ipairs(source_inputs) do
                if has_file_changed(f, nil) then
                    print("CHANGED "..f)
                    changes = true
                end
            end
        end
    end

    if not changes then
        return output
    end

    -- run the actual command since we've got changes
    print(cmd)
    if not os.execute(command_with_cd(cmd)) then
        print("Exited with errors!")
        os.exit(1)
    end

    build.database[output] = { ["mark"] = true, ["hash"] = 0, ["command"] = cmd, ["last_write"] = 0, ["deps"] = source_inputs, ["changed"] = true }
    return output
end

function build.ld_chain(inputs, flags, output)
    return build.chain(inputs, "clang %i "..flags.." -o %o", output)
end

function build.ar_chain(inputs, output)
    if ffi.os == "Windows" then
        return build.chain(inputs, "lib /nologo /out:%o %i", output)
    else
        return build.chain(inputs, "ar -rcs %o %i", output)
    end
end

function build.done()
    -- write new database
    database_file = io.open("my.cache", "wb")

    -- write out build options
    for input,entry in pairs(build.database) do
        if entry.mark == nil then
            -- garbage collect
            print("GCed "..input)
            
            build.del(input)
            build.database[input] = nil
        else
            -- clear changed field from database entries
            entry.mark = nil
            entry.changed = false
        end
    end

    database_file:write("return {\n [\"config\"] = ")
    serialize(database_file, config, 1)
    database_file:write(",\n")

    database_file:write("  [\"database\"] = ")
    serialize(database_file, build.database, 1)
    database_file:write("\n}\n")
    database_file:close()
end
