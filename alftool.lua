#!/usr/bin/env lua

local alf_hdr = "<c4I4I4l"
local alf_dirent = "<I4I4lB"

local parser = require("argparse")("alftool")
parser:mutex(
	parser:flag("-w --write", "Makes or updates an .alf file"),
	parser:option("-r --read", "Reads single file from an .alf file"),
	parser:flag("-x --extract", "Extracts an .alf file's contents"),
	parser:flag("-t --list", "Lists files in an .alf file")
)
parser:option("--convert-paths", "Convert paths to/from windows paths (on file extraction, it's implied)"):choices({"never", "write", "always"}):default("write")
parser:option("--directory", "Directory to output to. (default: <file>.out)")
parser:argument("file", "File to act on")
local args = parser:parse()

args.directory = args.directory or (args.file..".out")

local function arg_collapse(...)
	local argl = {...}
	for i=1, #argl do
		argl[i] = tostring(argl[i])
	end
	return table.concat(argl, "\t")
end

local function warn(...)
	io.stderr:write("\27[1;33m(warn) \27[22m",arg_collapse(...),"\n")
end

local function run_screaming(ec, ...)
	io.stderr:write("\27[1;31m(error) \27[22m",arg_collapse(...),"\n")
	os.exit(ec)
end

local function pack_read(file, packstr)
	local packsize = packstr:packsize()
	local d, err = file:read(packsize)
	if not d then run_screaming(1, "read failed:", err or "unknown error") end
	if #d ~= packsize then run_screaming(1, "unexpected eof") end
	return packstr:unpack(d)
end

local function prequire(pkg)
	local ok, res = pcall(require, pkg)
	if not ok then warn("could not find library", pkg) end
	return ok and res or nil
end

local lfs = prequire("lfs")
local zlib = prequire("zlib")

local function make_parent(path)
	if not lfs then run_screaming(-1, "can't extract without lfs!") end
	local parts = {}
	for part in path:gmatch("[^/]+") do
		table.insert(parts, part)
	end
	local cur_path = args.directory
	for i=1, #parts do
		if not lfs.attributes(cur_path) then
			--lfs.makeDirectory(cur_path) -- someone's been doing too much opencomputers
			lfs.mkdir(cur_path)
		end
		cur_path = cur_path .. "/" .. parts[i]
	end
end

local function from_windows(s)
	return (s:gsub("\\", "/"))
end

local function to_windows(s)
	return (s:gsub("/", "\\"))
end

local units = {"bytes", "KiB", "MiB", "GiB"}
local function to_human(n)
	local i = 1
	while n >= 1024 do
		n = n / 1024
		i = i + 1
	end
	return string.format((i==1 and "%d" or "%.1f").." %s", n, units[i])
end

-- sanity checks
if not (args.write or args.read or args.extract or args.list) then
	run_screaming(1, "must specify one of -rwxt")
end
--if args.write then run_screaming(-1, "TODO: implement write") end -- i can remove this now
if not lfs then warn("LuaFileSystem not found, you won't be able extract or write files!") end
if not zlib then warn("zlib not found, you won't be able to write files!") end
if args.convert_paths == "never" then warn("I hope you know what you're doing.") end

-- read
if (args.read or args.extract or args.list) then
	local f = io.open(args.file, "rb")
	-- read header
	local magic, flags, entries, table_ptr = pack_read(f, alf_hdr)
	-- no lz4 support at the moment
	if flags & 1 > 0 then run_screaming(2, "file is lz4 compressed!!!") end
	if magic ~= "KAI!" then
		run_screaming(1, "bad magic, expected KAI! got", magic)
	end
	f:seek("set", table_ptr)
	if args.list then
		print("CHECKSUM |           SIZE | PATH")
		print("---------+----------------+---------------------------------------------------")
	end
	local files = {}
	for i=1, entries do
		local csum, size, ptr, path_size = pack_read(f, alf_dirent)
		local path = f:read(path_size)
		if (args.convert_paths == "always") then
			path = from_windows(path)
		end
		if (args.list) then
			print(string.format("%.8x | %14s | %s", csum, to_human(size), path))
		end
		files[path] = {
			csum = csum,
			size = size,
			offset = ptr
		}
		table.insert(files, path)
	end
	if (args.list) then os.exit(0) end
	if (args.read) then
		local path = to_windows(args.read)
		if args.convert_paths == "always" then path = args.read end
		if not files[path] then
			run_screaming(1, "file not found: "..path)
		end
		local file = files[path]
		f:seek("set", file.offset)
		local d = f:read(file.size) -- this probably should be read in chunks
		io.stdout:write(d) -- but who cares
		os.exit(0)
	end
	if args.extract then
		for i=1, #files do
			local file = files[files[i]]
			local path = from_windows(files[i])
			make_parent(path)
			io.stderr:write(files[i], " => ", args.directory..path, "\n")
			local out, res = io.open(args.directory..path, "wb")
			if not out then run_screaming(1, "failed to open file", path, res) end
			f:seek("set", file.offset)
			local d = f:read(file.size)
			out:write(d)
			out:close()
		end
	end
elseif args.write then -- write
	if not lfs or not zlib then run_screaming(1, "missing a required library, can't continue!") end
	local h = io.open(args.file, "wb")
	h:write((alf_hdr:pack("KAI!", 0, 0, 0)))
	local files = {}
	for line in io.stdin:lines() do
		local stat = lfs.attributes(line)
		if stat.mode == "file" then
			local inf = io.open(line, "rb")
			local crc = zlib.crc32()
			local ptr = h:seek("cur", 0)
			local size = 0
			while true do
				local indat, err = inf:read(1024*1024)
				if not indat then run_screaming(1, "read error for file", line, err) end
				size = size + #indat
				crc(indat)
				h:write(indat)
				if #indat ~= 1024*1024 then break end
			end
			inf:close()
			if size ~= stat.size then run_screaming(1, "i/o error: ", string.format("%d ~= %d", stat.size, size)) end
			local rpath = (args.convert_paths ~= "never") and to_windows("/"..line) or ("\\"..line)
			io.stderr:write(line, " => ", rpath, "\n")
			table.insert(files, {
				path = rpath,
				offset = ptr,
				size = stat.size,
				crc = crc()
			})
		end
	end
	local table_offset = h:seek("cur", 0)
	h:seek("set", 0)
	h:write((alf_hdr:pack("KAI!", 0, #files, table_offset)))
	h:seek("set", table_offset)
	for i=1, #files do
		local f = files[i]
		h:write((alf_dirent:pack(f.crc, f.size, f.offset, #f.path)),f.path)
	end
	h:close()
else -- just in case, i guess
	run_screaming(-1, "how did we get here")
end