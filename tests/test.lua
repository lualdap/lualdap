#!/usr/bin/env busted
---------------------------------------------------------------------
-- LuaLDAP test file.
-- This test will create a copy of an existing entry on the
-- directory to work on.  This new entry will be modified,
-- renamed and deleted at the end.
--
-- See Copyright Notice in license.md
---------------------------------------------------------------------

local getenv = require("os").getenv
local unpack = assert(require("table")).unpack or unpack

local assert = assert(require("luassert"))
local say = assert(require("say"))

local lualdap = assert(require("lualdap"))

local URI = assert(getenv("LDAP_URI"))
local HOSTNAME = assert(getenv("LDAP_HOST"))
local BASE = assert(getenv("LDAP_BASE_DN"))
local WHO = assert(getenv("LDAP_TEST_DN"))
local BIND_DN = assert(getenv("LDAP_BIND_DN"))
local PASSWORD = assert(getenv("LDAP_BIND_PASSWORD"))

local function set_failure_message(state, message)
	if message ~= nil then
		state.failure_message = message
	end
end

local function returned_future(state, arguments, level)
	local expected_return_value = arguments[1]
	local f = arguments[2]
	local ok, future = pcall(f, unpack(arguments, 3))
	if not ok then
		set_failure_message(state, "Call was not successful: "..tostring(future))
		return false
	elseif type(future) ~= "function" then
		set_failure_message(state, "Call did not return a function: "..type(future))
		return false
	else
		local return_value = future()
		if return_value ~= expected_return_value then
			set_failure_message(state, "Future did not return expected value (expected: "..tostring(expected_return_value)..", got: "..tostring(return_value)..")")
			return false
		end
	end

	return true
end

say:set_namespace("en")
say:set("assertion.returned_future.positive", "Expected call to return a future %s:\n%s")
say:set("assertion.returned_future.negative", "Expected call not to return a future %s:\n%s")
assert:register("assertion", "returned_future", returned_future, "assertion.returned_future.positive", "assertion.returned_future.negative")


local function is_calleable(state, arguments)
	local f = arguments[1]
	if type(f) == "function" then
		return true
	else
		local mt = getmetatable(f)
		if type(mt) == "table" then
			return mt.__call ~= nil
		end
	end
	return false
end

say:set_namespace("en")
say:set("assertion.is_calleable.positive", "Expected calleable object or function, but got:\n%s")
say:set("assertion.is_calleable.negative", "Expected non-calleable object or non-function, but got:\n%s")
assert:register("assertion", "is_calleable", is_calleable, "assertion.is_calleable.positive", "assertion.is_calleable.negative")

--
local DN_PAT = "^([^,=]+)%=([^,]+)%,?(.*)$"

--[=[
---------------------------------------------------------------------
-- Print attributes.
---------------------------------------------------------------------
local function print_attrs (dn, attrs)
	if not dn then
		io.write ("nil\n")
		return
	end
	io.write (string.format ("\t[%s]\n", dn))
	for name, values in pairs (attrs) do
		io.write ("["..name.."] : ")
		local tv = type (values)
		if tv == "string" then
			io.write (values)
		elseif tv == "table" then
			local n = #values
			for i = 1, n-1 do
				io.write (values[i]..",")
			end
			io.write (values[n])
		end
		io.write ("\n")
	end
end
]=]

---------------------------------------------------------------------
-- clone a table.
---------------------------------------------------------------------
local function clone (tab)
	local new = {}
	for i, v in pairs (tab) do
		new[i] = v
	end
	return new
end


---------------------------------------------------------------------
-- object test.
---------------------------------------------------------------------
local function test_object (obj, objmethods, pattern)
	-- checking object type.
	it("is a userdata object", function()
		assert.is_userdata(obj)
	end)
	-- trying to get metatable.
	it("is not permitted to access the object's metatable", function()
		assert.is_same("LuaLDAP: you're not allowed to get this metatable",
			getmetatable(obj))
	end)
	it("cannot set metatable", function()
		assert.is_false(pcall(setmetatable, obj, {}))
	end)
	-- checking existence of object's methods.
	for i = 1, #objmethods do
		local method = obj[objmethods[i]]
		it(objmethods[i].." is a function", function()
			assert.is_function(method)
		end)
		it("is not acceptable to call the "..objmethods[i].." without 'self'", function()
			assert.is_false(pcall(method))
		end)
	end
	-- checking __tostring
	local str = tostring(obj)
	it("call its __tostring", function()
		assert.is_string(str:match(pattern))
	end)
	return obj
end

local function CONN_OK (obj, err)
	if obj == nil then
		error (err, 2)
	end
	return test_object (obj, { "close", "add", "compare", "delete", "modify", "rename", "search", }, '^LuaLDAP connection %(0x%x+%)$')
end

---------------------------------------------------------------------
-- basic checking test.
---------------------------------------------------------------------
describe("basics", function()
	local ld = CONN_OK (lualdap.initialize (URI))
	it("can connect and bind", function()
		assert.is_same(ld, ld:bind_simple (BIND_DN, PASSWORD))
	end)
	it("can close connection", function()
		assert.is_same(1, ld:close())
	end)
	it("show as closed", function()
		assert.is_same(tostring(ld), "LuaLDAP connection (closed)")
	end)
	it("cannot close without a connection", function()
		assert.is_false(pcall(ld.close))
	end)
	it("cannot close an invalid connection", function()
		assert.is_false(pcall(ld.close, io.output()))
	end)
	local _,_,rdn_name,rdn_value = string.find (BASE, DN_PAT)
	it("is not permitted to use a closed connection", function()
		assert.is_false(pcall(ld.compare, ld, BASE, rdn_name, rdn_value))
	end)
	it("is ok to close a closed object, but nil is returned instead of 1", function()
		assert.is_nil(ld:close())
	end)
	it("is an error to connect to an invalid host", function()
		assert.is_nil(lualdap.open_simple ("unknown-server"))
	end)
end)

describe("creating a connection using a hostname", function()
	local ld = CONN_OK (lualdap.open_simple (HOSTNAME, BIND_DN, PASSWORD))
	it("can close connection", function()
		assert.is_same(1, ld:close())
	end)
end)

describe("creating a connection with connection timeout", function()
	local ld = CONN_OK (lualdap.open_simple (HOSTNAME, BIND_DN, PASSWORD, false, 60))
	it("can close connection", function()
		assert.is_same(1, ld:close())
	end)
end)

describe("tests on an existing connection", function()
	local LD, CLOSED_LD

	-- reopen the connection.
	setup(function()
		-- first, try using TLS
		local ok, err = lualdap.open_simple (HOSTNAME, BIND_DN, PASSWORD, true)
		if not ok then
			ok, err = lualdap.open_simple (HOSTNAME, BIND_DN, PASSWORD, false)
		end
		LD = assert(ok, err)
		collectgarbage()
	end)

---------------------------------------------------------------------
-- checking compare operation.
---------------------------------------------------------------------
describe("compare operation", function()
	local _,_,rdn_name,rdn_value = string.find (BASE, DN_PAT)

	it("preparations", function()
		assert.message("could not extract RDN name").is_string(rdn_name)
		assert.message("could not extract RDN value").is_string(rdn_value)
	end)
	-- comparing against the correct value.
	it(rdn_name.." = "..rdn_value.." should be true", function()
		assert.returned_future(true, LD.compare, LD, BASE, rdn_name, rdn_value)
	end)
	-- comparing against a wrong value.
	it(rdn_name.." = "..rdn_value.." should be false", function()
		assert.returned_future(false, LD.compare, LD, BASE, rdn_name, rdn_value..'_')
	end)
	-- comparing against an incorrect attribute name.
	it(rdn_name.." = "..rdn_value.." should be nil", function()
		assert.returned_future(nil, LD.compare, LD, BASE, rdn_name..'x', rdn_value)
	end)
	-- comparing on a wrong base.
	it("Comparing on a wrong base should be nil", function()
		assert.returned_future(nil, LD.compare, LD, 'qwerty', rdn_name, rdn_value)
	end)
	-- comparing with a closed connection.
	it("Comparing with a closed connection should fail", function()
		assert.is_false(pcall(LD.compare, CLOSED_LD, BASE, rdn_name, rdn_value))
	end)
	-- comparing with an invalid userdata.
	it("Comparing with an invalid connection should fail", function()
		assert.is_false(pcall(LD.compare, io.output(), BASE, rdn_name, rdn_value))
	end)
end)


---------------------------------------------------------------------
-- checking basic search operation.
---------------------------------------------------------------------
describe("basic search operation", function()
	local iter, upvalue

	setup(function()
		local _,_,rdn = string.find (WHO, "^([^,]+)%,.*$")
		iter = LD:search {
			base = BASE,
			scope = "onelevel",
			sizelimit = 1,
			filter = "("..rdn..")",
		}
		_, upvalue = debug.getupvalue(iter, 1)
		collectgarbage()
	end)
	it("search returns something", function()
		assert.is_not_nil(iter)
	end)
	it("search returns future", function()
		assert.is_calleable(iter)
	end)
	it("the upvalue is a LuaLDAP search", function()
		if upvalue then
			local str = tostring(upvalue)
			assert.is_userdata(upvalue)
			assert.is_string(str:match('^LuaLDAP search %(0x%x+%)$'))
		else
			assert.is_nil(upvalue)  -- PUC Lua 5.1
		end
	end)
	CONN_OK (LD)
	it("search result iterator returns DN and value", function()
		local dn, entry = iter ()
		assert.is_string(dn)
		assert.is_table(entry)
	end)
	it("search result iterator stays healthy after retrieving first result", function()
		collectgarbage()
		assert.is_calleable(iter)
	end)
	CONN_OK (LD)
end)


---------------------------------------------------------------------
-- checking advanced search operation.
---------------------------------------------------------------------
describe("advanced search operation", function()
	local iter

	setup(function()
		local _,_,rdn = string.find (WHO, "^([^,]+)%,.*$")
		iter = LD:search {
			base = BASE,
			scope = "onelevel",
			sizelimit = 1,
			filter = "("..rdn..")",
		}
		collectgarbage()
	end)

	it("search returns something", function()
		assert.is_not_nil(iter)
	end)
	it("search returns future", function()
		assert.is_calleable(iter)
	end)
	it("search result iterator does not misbehave under garbage collection", function()
		collectgarbage ()
		assert.is_calleable(iter)
	end)
	it("search result iterator returns DN and value", function()
		local dn, entry = iter ()
		assert.is_string(dn)
		assert.is_table(entry)
	end)
	it("search result iterator stays healthy after retrieving first result", function()
		collectgarbage ()
		assert.is_calleable(iter)
	end)
	it("cannot search without specification", function()
		assert.is_false(pcall (LD.search, LD))
	end)
	it("cannot search with invalid scope", function()
		assert.is_false(pcall (LD.search, LD, { scope = 'BASE', base = BASE, }))
	end)
	it("cannot search with invalid base", function()
		assert.returned_future(nil, LD.search, LD, { base = "invalid", scope = "base", })
	end)
end)


---------------------------------------------------------------------
-- wrap tests further down the file, which need certain variables.
---------------------------------------------------------------------
describe("tests using ENTRY and NEW_DN", function()
	local DN, NEW_DN, ENTRY
	local rdn_name, new_rdn_value, parent_dn

	setup(function()
		local _,_,rdn = string.find (WHO, "^([^,]+)%,.*$")
		DN, ENTRY = LD:search {
			base = BASE,
			scope = "onelevel",
			sizelimit = 1,
			filter = "("..rdn..")",
		}()
		collectgarbage()
		local _, rdn_value
		_,_,rdn_name, rdn_value, parent_dn = string.find (DN, DN_PAT)
		new_rdn_value = rdn_value.."_copy"
		NEW_DN = string.format ("%s=%s,%s", rdn_name, new_rdn_value, parent_dn)
	end)

	it("DN and ENTRY contain sane values", function()
		assert.is_string(DN)
		assert.is_table(ENTRY)
	end)


---------------------------------------------------------------------
-- checking add operation.
---------------------------------------------------------------------
describe("add operation", function()
	local NEW

	setup(function()
		-- clone an entry.
		NEW = clone (ENTRY)
		NEW[rdn_name] = new_rdn_value
	end)

	it("cannot insert an entry with a wrong connection", function()
		assert.is_false(pcall(LD.add, CLOSED_LD, NEW_DN, NEW))
	end)
	it("cannot insert an entry with an invalid connection", function()
		assert.is_false(pcall(LD.add, io.output(), NEW_DN, NEW))
	end)
	it("cannot insert an entry with a wrong DN", function()
		local wrong_dn = string.format ("%s_x=%s,%s", rdn_name, NEW_DN, parent_dn)
		assert.returned_future (nil, LD.add, LD, wrong_dn, NEW)
	end)
	it("can insert the clone on the LDAP data base", function()
		assert.returned_future(true, LD.add, LD, NEW_DN, NEW)
	end)
	it("cannot reinsert the clone entry on the directory", function()
		assert.returned_future(nil, LD.add, LD, NEW_DN, NEW)
	end)
end)


---------------------------------------------------------------------
-- checking modify operation.
---------------------------------------------------------------------
describe("modify operation", function()
	it("cannot modify without connection", function()
		assert.is_false(pcall (LD.modify, nil, NEW_DN, {}))
	end)
	it("cannot modify with a closed connection", function()
		assert.is_false(pcall (LD.modify, CLOSED_LD, NEW_DN, {}))
	end)
	it("cannot modify with an invalid userdata", function()
		assert.is_false(pcall (LD.modify, io.output(), NEW_DN, {}))
	end)
	it("cannot modify invalid DN", function()
		assert.is_false(pcall (LD.modify, LD, {}))
	end)
	it("can apply empty modification", function()
		assert.returned_future(true, LD.modify, LD, NEW_DN)
	end)
	it("cannot modify without operation", function()
		local a_attr, a_value = next (ENTRY)
		assert.is_false(pcall (LD.modify, LD, NEW_DN, { [a_attr] = "abc"}))
	end)
	it("cannot modify an unknown entry", function()
		local _,_, rdn_name, rdn_value, parent_dn = string.find (NEW_DN, DN_PAT)
		local new_rdn = rdn_name..'='..rdn_value..'_'
		local new_dn = string.format ("%s,%s", new_rdn, parent_dn)
		assert.returned_future(nil, LD.modify, LD, new_dn)
	end)
	it("cannot create an undefined attribute", function()
		assert.returned_future(nil, LD.modify, LD, NEW_DN, {'+', unknown_attribute = 'a'})
	end)
end)


---------------------------------------------------------------------
local function count (tab)
	local counter = 0
	for dn, entry in LD:search (tab) do
		counter = counter + 1
	end
	return counter
end

local function count_attrs (tab)
	local counter = 0
	for dn, entry in LD:search (tab) do
		for k,v in pairs(entry) do
			counter = counter + 1
		end
	end
	return counter
end

---------------------------------------------------------------------
-- checking even more advanced search operation.
---------------------------------------------------------------------
describe("even more advanced search operation", function()
	local filter

	setup(function()
		local _,_, rdn_name, rdn_value, parent_dn = string.find (NEW_DN, DN_PAT)
		filter = string.format ("(%s=%s)", rdn_name, rdn_value)
	end)

	it("filter works", function()
		assert.is_same(1, count { base = BASE, scope = "subtree", filter = filter, })
	end)
	it("sizelimit works", function()
		assert.is_same(1, count { base = BASE, scope = "subtree", sizelimit = 1, })
	end)
	it("attrsonly works", function()
		for dn, entry in LD:search { base = BASE, scope = "subtree", attrsonly = true, } do
			for attr, value in pairs (entry) do
				assert.message("attrsonly failed").is_true(value)
			end
		end
	end)
	it("attrs as string works", function()
		assert.is_same(1, count { base = BASE, scope = "subtree", filter = filter, attrs = "mail", })
	end)
	it("attrs as table works", function()
		local attrs = {"name", "organization", "not_in_ldap"}
		local tab = { base = BASE, scope = "subtree", filter = filter, attrs = attrs }
		assert.is_same(1, count(tab))
		assert.is_same(4, count_attrs(tab))
	end)
	it("reusing search objects is possible", function()
		local iter = assert.is_not_nil(LD:search { base = BASE, scope = "base", })
		assert.is_calleable(iter)
		local dn, e1 = iter()
		assert.is_string(dn)
		assert.is_table(e1)
		dn, e1 = iter()
		assert.is_nil(dn)
		assert.is_nil(e1)
		assert.is_false(pcall(iter))
	end)
end)


---------------------------------------------------------------------
-- checking rename operation.
---------------------------------------------------------------------
describe("rename operation", function()
	local new_dn, new_rdn, rdn_name, rdn_value, parent_dn

	setup(function()
		local _
		_,_, rdn_name, rdn_value, parent_dn = string.find (NEW_DN, DN_PAT)
		new_rdn = rdn_name..'='..rdn_value..'_'
		new_dn = string.format ("%s,%s", new_rdn, parent_dn)
	end)

	it("cannot rename with no parent", function()
		assert.returned_future(true, LD.rename, LD, NEW_DN, new_rdn, nil)
	end)
	it("cannot rename an invalid dn", function()
		assert.returned_future(nil, LD.rename, LD, NEW_DN, new_rdn, nil)
	end)
	it("can rename with the same parent", function()
		assert.returned_future(true, LD.rename, LD, new_dn, rdn_name..'='..rdn_value, parent_dn)
	end)
	it("cannot rename to an inexistent parent", function()
		assert.returned_future(nil, LD.rename, LD, NEW_DN, new_rdn, new_dn)
	end)
	it("cannot rename with a mal-formed DN", function()
		assert.is_false(pcall (LD.rename, LD, ""))
	end)
	it("cannot rename with a closed connection", function()
		assert.is_false(pcall (LD.rename, CLOSED_LD, NEW_DN, new_rdn, nil))
	end)
	it("cannot rename with an invalid connection", function()
		assert.is_false(pcall (LD.rename, io.output(), NEW_DN, new_rdn, nil))
	end)
end)


---------------------------------------------------------------------
-- checking delete operation.
---------------------------------------------------------------------
describe("delete operation", function()
	it("cannot delete with a closed connection", function()
		assert.is_false(pcall (LD.delete, CLOSED_LD, NEW_DN))
	end)
	it("cannot delete with an invalid connection", function()
		assert.is_false(pcall (LD.delete, io.output(), NEW_DN))
	end)
	it("deleting new entry", function()
		assert.returned_future(true, LD.delete, LD, NEW_DN)
	end)
	it("deleting an already deleted entry", function()
		assert.returned_future(nil, LD.delete, LD, NEW_DN)
	end)
	it("deleting a mal-formed DN", function()
		assert.returned_future(nil, LD.delete, LD, "")
	end)
	it("deleting a nil DN", function()
		assert.is_false(pcall(LD.delete, LD))
	end)
end)


---------------------------------------------------------------------
-- checking close operation.
---------------------------------------------------------------------
describe("close operation", function()
	it("can close connection", function()
		assert.message("couldn't close connection").is_same(1, LD:close())
	end)
end)

end)

end)
