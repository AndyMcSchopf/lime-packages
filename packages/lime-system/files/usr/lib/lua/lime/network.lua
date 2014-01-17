#!/usr/bin/lua

network = {}

local bit = require "nixio".bit
local ip = require "luci.ip"
local config = require "lime.config"
local utils = require "lime.utils"

function network.get_mac(ifname)
	local mac = assert(fs.readfile("/sys/class/net/"..ifname.."/address")):gsub("\n","")
	return utils.split(mac, ":")
end

function network.primary_interface()
	return config:get("network", "primary_interface")
end

function network.primary_mac()
	return network.get_mac(network.primary_interface())
end

function network.primary_address()
	local ipv4_template = config:get("network", "ipv4_address")
	local ipv6_template = config:get("network", "ipv6_address")
	local pm = network.primary_mac()
	
	for i=1,6,1 do
		ipv6_template = ipv6_template:gsub("M" .. i, pm[i])
		ipv4_template = ipv4_template:gsub("M" .. i, tonumber(pm[i], 16))
	end

	return ip.IPv4(ipv4_template), ip.IPv6(ipv6_template) 
end

function network.eui64(mac)
    local function flip_7th_bit(x) return utils.hex(bit.bxor(tonumber(x, 16), 2)) end

    local t = utils.split(mac, ":")
    t[1] = flip_7th_bit(t[1])

    return string.format("%s%s:%sff:fe%s:%s%s", t[1], t[2], t[3], t[4], t[5], t[6])
end

--@DEPRECATED We should implement a proto for this too
function network.setup_lan(ipv4, ipv6)
	uci:set("network", "lan", "ip6addr", ipv6:string())
	uci:set("network", "lan", "ipaddr", ipv4:host():string())
	uci:set("network", "lan", "netmask", ipv4:mask():string())
	uci:set("network", "lan", "ifname", "eth0 bat0")
	uci:save("network")
end

--@DEPRECATED We should implement a proto for this too
function network.setup_anygw(ipv4, ipv6)
    local n1, n2, n3 = network_id()

    -- anygw macvlan interface
    print("Adding macvlan interface to uci network...")
    local anygw_mac = string.format("aa:aa:aa:%02x:%02x:%02x", n1, n2, n3)
    local anygw_ipv6 = ipv6:minhost()
    local anygw_ipv4 = ipv4:minhost()
    anygw_ipv6[3] = 64 -- SLAAC only works with a /64, per RFC
    anygw_ipv4[3] = ipv4:prefix()

    uci:set("network", "lm_anygw_dev", "device")
    uci:set("network", "lm_anygw_dev", "type", "macvlan")
    uci:set("network", "lm_anygw_dev", "name", "anygw")
    uci:set("network", "lm_anygw_dev", "ifname", "@lan")
    uci:set("network", "lm_anygw_dev", "macaddr", anygw_mac)

    uci:set("network", "lm_anygw_if", "interface")
    uci:set("network", "lm_anygw_if", "proto", "static")
    uci:set("network", "lm_anygw_if", "ifname", "anygw")
    uci:set("network", "lm_anygw_if", "ip6addr", anygw_ipv6:string())
    uci:set("network", "lm_anygw_if", "ipaddr", anygw_ipv4:host():string())
    uci:set("network", "lm_anygw_if", "netmask", anygw_ipv4:mask():string())

    local content = { insert = table.insert, concat = table.concat }
    for line in io.lines("/etc/firewall.user") do
        if not line:match("^ebtables ") then content:insert(line) end
    end
    content:insert("ebtables -A FORWARD -j DROP -d " .. anygw_mac)
    content:insert("ebtables -t nat -A POSTROUTING -o bat0 -j DROP -s " .. anygw_mac)
    fs.writefile("/etc/firewall.user", content:concat("\n").."\n")

    -- IPv6 router advertisement for anygw interface
    print("Enabling RA in dnsmasq...")
    local content = { }
    table.insert(content,               "enable-ra")
    table.insert(content, string.format("dhcp-range=tag:anygw, %s, ra-names", anygw_ipv6:network(64):string()))
    table.insert(content,               "dhcp-option=tag:anygw, option6:domain-search, lan")
    table.insert(content, string.format("address=/anygw/%s", anygw_ipv6:host():string()))
    table.insert(content, string.format("dhcp-option=tag:anygw, option:router, %s", anygw_ipv4:host():string()))
    table.insert(content, string.format("dhcp-option=tag:anygw, option:dns-server, %s", anygw_ipv4:host():string()))
    table.insert(content,               "dhcp-broadcast=tag:anygw")
    table.insert(content,               "no-dhcp-interface=br-lan")
    fs.writefile("/etc/dnsmasq.conf", table.concat(content, "\n").."\n")

    -- and disable 6relayd
    print("Disabling 6relayd...")
    fs.writefile("/etc/config/6relayd", "")
end

function network.setup_rp_filter()
	local sysctl_file_path = "/etc/sysctl.conf";
	local sysctl_options = "";
	local sysctl_file = io.open(sysctl_file_path, "r");
	while sysctl_file:read(0) do
		local sysctl_line = sysctl_file:read();
		if not string.find(sysctl_line, ".rp_filter") then sysctl_options = sysctl_options .. sysctl_line .. "\n" end 
	end
	sysctl_file:close()
	
	sysctl_options = sysctl_options .. "net.ipv4.conf.default.rp_filter=2\nnet.ipv4.conf.all.rp_filter=2\n";
	sysctl_file = io.open(sysctl_file_path, "w");
	sysctl_file:write(sysctl_options);
	sysctl_file:close();
end

function network.clean()
    print("Clearing network config...")
    
    uci:delete("network", "globals", "ula_prefix")
    
    uci:foreach("network", "interface", function(s)
        if s[".name"]:match("^lm_") then
            uci:delete("network", s[".name"])
        end
    end)
end

function network.scandevices()
	devices = {}
	local devList = {}
	local devInd = 0
	
	-- Scan for plain ethernet interface
	devList = utils.split(io.popen("ls -1 /sys/class/net/"):read("*a"), "\n")
	for i=1,#devList do
		if devList[i]:match("eth%d") then
			devices[devInd] = devList[i]
			devInd = devInd + 1
		end
	end
	
	-- Scan for mac80211 wifi devices
	devList = utils.split(io.popen("ls -1 /sys/class/ieee80211/"):read("*a"), "\n")
	for i=1,#devList do
		if devList[i]:match("phy%d") then
			devices[devInd] = devList[i]
			devInd = devInd + 1
		end
	end
	
	-- When we will support other device type just scan for them here
	
	return devices
end

function network.configure()
	network.clean()
	
	local protocols = config:get("network", "protocols")
	local ipv4, ipv6 = network.primary_address() -- for br-lan

	network.setup_rp_filter()
	network.setup_lan(ipv4, ipv6)
	network.setup_anygw(ipv4, ipv6)

	local specificIfaces = {};
	config.foreach("net", function(iface) specificIfaces[iface[".name"]] = iface end)
	
	-- Scan for fisical devices, if there is a specific config apply that otherwise apply general config
	local fisDev = network.scandevices()
	for i=1,#fisDev do
		local pif = specificIfaces[fisDev[i]]
		if pif then
			for j=1,#pif["protocols"] do
				local args = utils.split(pif["protocols"][j], ":")
				if args[1] == "manual" then break end -- If manual is specified do not configure interface
				local proto = require("lime.proto."..args[1])
				proto.setup_interface(fisDev[i], args)
			end
		else
			local protos = config.get("net","protocols")
			for p=1,#protos do
				local args = utils.split(protos[p], ":")
				local proto = require("lime.proto."..args[1])
				proto.setup_interface(fisDev[i], args)
			end
		end
	end
end

function network.apply()
    -- TODO (i.e. /etc/init.d/network restart)
end

function network.init()
    -- TODO
end

return network
