#!/usr/bin/ruby
require "ipaddr"
require "date"
#########################################################################################
# Bugs to address / think about
# jmb - in start() for processes, should it look to kill the process if already running?
#########################################################################################
########################################################################################
# Version - of the form major.minor.revision
# Feb 15, 2024 - Fixed IP address saving
# Apri 29, 2024 - Add reboot option
# April 1, 2024 - C1.1.19, added realtek radio hack

# April 18, 2024 - 1.1.20 - Added new confighash method
# April 19, 2024 - 1.1.21 - change channels to integer
# April 19, 2024 - 1.1.22 - Fix string to array conversion
# April 28, 2024 - 1.1.23 - Add diaassoc event 
########################################################################################

MAJOR = 1
MINOR = 0
REVISION = 23

# If the following files exists, their content will the the portal IP address.
# and the port number
CUSTOMPORTAL = "customportal.txt"
CUSTOMPORT = "customport.txt"

# Set controller address is customportal.txt has an address
CONTROLLER = "cloudwifi.org" # Cloud server
if File.exist?(CUSTOMPORTAL)
  CONTROLLER = `cat #{CUSTOMPORTAL}`.chomp
end
puts "Portal: #{CONTROLLER}"
# Set Controller Port
PORT = 3000   # default
if File.exist?(CUSTOMPORT)
  PORT = `cat #{CUSTOMPORT}`.chomp
end
puts "Port: #{PORT}"

# Default Sleep Time in seconds
DEFAULT_SLEEP = 5

# require 'active_support/core_ext/object/blank'

# Wifi State Machine Code
require "rubygems"
require "httparty"
require "json"
require "logger"
require "fileutils"
require "set"
require "socket"

# Number of retries on message failure from the wifictlr
CLOUD_RETRIES = 10

# Number of times to attempt to restart a process
PROC_RESTART_RETRIES = 5

# Wifi current HASHES
# cur_config_hash = "FFFFFFFFFFFFFFF"
# cur_pmk_hash = "FFFFFFFFFFFFFFF"

# pmks - stores that current PMK hash, with PMK->{pmk, user_id, maxdev, upmax, downmax }
@pmks = {}

# Wifi current connection states as a hash mapping client macs to information
# MAC -> {'event', 'time', 'mac', 'pmk', 'vid'}
@connection_states = {}

# PMK file uname
PMK_FILE = "/tmp/hostapd.wpa_pmk_file"

# hostapd.conf
HOSTAPD_FILE = "/tmp/hostapd.conf"

# map pmk to user names
@pmk_to_user_id = {}
@my_ip_add = `hostname -I | awk '{print $1}'`.chomp

def string_to_array(string) 
  string.scan(/\d+/).map(&:to_i) 
end
#################################################################
# puts and print overrides to redirect to logging engine.
#################################################################
$logger = nil
def puts(o1, o2 = nil, o3 = nil)
  line = o1.to_s
  if !o2.nil? then line += o2.to_s end
  if !o3.nil? then line += o3.to_s end

  line = line.strip

  # Removes all unprintable characters from a line.
  line = line.gsub(/[^[:print:]]/, "")

  if line.length == 0
    return
  end

  # output to STDOUT
  super(line)

  # output to log file
  if !$logger.nil?
    $logger.info(line)
  end
end

def print(o1, o2 = nil, o3 = nil, o4 = nil, o5 = nil, o6 = nil)
  line = o1.to_s
  if !o2.nil? then line += o2.to_s end
  if !o3.nil? then line += o3.to_s end
  if !o4.nil? then line += o4.to_s end
  if !o5.nil? then line += o5.to_s end
  if !o6.nil? then line += o6.to_s end

  # Call above override.
  puts(line)
end

#################################################################
#
# State Machine States
#
#################################################################
module STATES
  START = 0   # Waiting from approval
  CONFIG = 1   # Waiting for config
  HEALTH = 2   # Heath notice - bad config or pmk
  RUN = 3   # AP is running
  DISABLING = 4   # Need to disable radios
  WAITGW = 5   # Wait for gateway address
end

module PROCESS_STATES
  DOWN = 0  # This instance is not running
  RUN = 1 # This instance is running
end

module WLAN_STATES
  OFF = 0 # Not being used
  AP = 1 # Being used as an AP
  SCAN = 2 # Being used for monitoring
  WAIT_AP = 4 # Waiting to start as AP
end

#################################################################
#
# A function to "fix up" USB interfaces that need help
# In the future should make it scan for the device first
# This is a terrible siolution, but it works by retrying until it succeeds
#
#################################################################
def update_usb_radios
  puts "Checking for usb radios that need special attention."
  # 0bda:1a2b Realtek Semiconductor Corp. RTL8188GU 802.11n WLAN Adapter (Driver CDROM Mode)
  radios = `lsusb`
  puts "RADIOS: #{radios}"
  while radios.include?("0bda:1a2b")
    puts "Found Realtek Semiconductor Corp. 802.11ac NIC 0bda:1a2b"
    result = `usb_modeswitch -KW -v 0bda -p 1a2b`
    # puts "RESULT: #{result}"
    radios = `lsusb`
    # puts "RADIOS: #{radios}"
    sleep(1)
  end
  puts "Radio Update complete"
end

#################################################################
#
# A class for managing and monitoring hostapd instances
#
#################################################################
class Hostapd_instance
  def initialize(wlan)
    @pid = 0
    @conf_file = "/tmp/hostapd." + wlan + ".conf"
    @wlan = wlan
    @state = WLAN_STATES::OFF
    @thread = nil
    @ssid = ""
  end

  def is_running
    if @pid == 0
      puts "HOSTAP no PID"
      return false
    end
    print "HOSTAPD PID " + @pid.to_s + " "
    # ps = `ps aux | grep hostapd`
    # puts ps
    cmd = "kill -0 " + @pid.to_s
    result = `#{cmd}`
    if $?.success?
      print @wlan, " hostapd running", "\n"
      true
    else
      @pid = 0
      print @wlan, " hostapd not running", "\n"
      false
    end
  end

  attr_reader :state

  attr_reader :wlan

  def set_ssid(ssid)
    @ssid = ssid
  end

  attr_reader :ssid

  def set_to_start
    @state = WLAN_STATES::WAIT_AP
  end

  def run_or_hup(state)
    # See if running
    puts "run_or_hup #{@pid}"
    # ps = `ps aux | grep hostapd`
    # puts ps
    if is_running
      print @wlan, "hostapd HUP the process", "\n"
      cmd = "kill -HUP " + @pid.to_s
      `#{cmd}`
      # ps = `ps aux | grep hostapd`
      # puts ps
    end
    print "Start the HOSTAPD process for ", @wlan, "\n"

    cmd = "/usr/sbin/hostapd -f /tmp/hostapd.#{@wlan}.log #{@conf_file}"
    puts "Start HOSTAPD: #{cmd}"
    @pid = Process.spawn(cmd)
    Process.detach(@pid)

    print "Start hostapd for ", @wlan, "PID:", @pid, "\n"
    # ps = `ps aux | grep hostapd`
    # puts ps

    @state = state
  end

  def stop
    if @pid > 0 and is_running
      print "Stopping hostapd for ", @wlan, " pid: ", @pid, ".\n"
      cmd = "kill -9 " + @pid.to_s
      `#{cmd}`
      @pid = 0
      # ps = `ps aux | grep hostapd`
      # puts ps

      # also we need to down wlan or else SSID is still broadcast
      cmd = "ifconfig #{@wlan} down"
      `#{cmd}`
      cmd = "ifconfig #{@wlan} up"
      `#{cmd}`
    else
      print "Error Stopping hostapd", @wlan, " pid: ", @pid, ".\n"
    end
    @state = WLAN_STATES::OFF
  end

  def get_pid
    pid
  end
end

#################################################################
#
# A class for managing and monitoring wlanbridge instance
#
#################################################################
class Wlanbridge_instance
  def initialize
    @pid = 0
    @wlan = ""
    @state = PROCESS_STATES::DOWN
    @thread = nil
  end

  def is_running
    if @pid == 0
      return false
    end
    print "Bridge PID " + @pid.to_s + " "
    cmd = "kill -0 " + @pid.to_s
    result = `#{cmd}`
    if $?.success?
      puts "Bridge Running"
      true
    else
      @pid = 0
      puts "Bridge Not Running"
      false
    end
  end

  def run(wlans, static_vids)
    @wlans = wlans

    puts "Start the wlanbridge process"
    cmd = "/opt/wlanbridge/bridge eth0 "
    wlans.each do |wlan|
      if static_vids.key?(wlan)
        puts "static_vids[wlan]: " + static_vids[wlan].inspect
        STDOUT.flush
        cmd = cmd + wlan + ":" + static_vids[wlan][:static_vid].to_s + ":" + static_vids[wlan][:ssid].to_s + " "
      else
        cmd = cmd + wlan + " "
      end
    end

    cmd += " -f /tmp/wlanbridge.log"
    puts cmd

    @pid = Process.spawn(cmd)
    Process.detach(@pid)

    print "Start wlanbridge: ", @pid, " on ", wlans, "\n"
    @state = PROCESS_STATES::RUN
  end

  def stop
    if @pid > 0 and is_running
      print "Stopping wlanbridge: ", @pid, " on ", @wlan, "\n"
      cmd = "pkill bridge"
      # cmd = "kill -9 " + @pid.to_s
      `#{cmd}`
      @pid = 0
    end
    @state = PROCESS_STATES::DOWN
  end

  def get_pid
    pid
  end
end

#################################################################
#
# A class for keeping track of a radius client instance
#
#################################################################
class Radiusclient_instance
  def initialize
    @pid = 0
    @state = PROCESS_STATES::DOWN
    @thread = nil

    @radius_server = nil
    @radius_secret = nil
  end

  def is_running
    if @pid == 0
      return false
    end

    print "Checking Radius Client PID " + @pid.to_s + " "
    begin
      !!Process.kill(0, @pid)
    rescue
      false
    end
  end

  def set_params(radius_server: nil, radius_secret: nil)
    if !radius_server.nil?
      @radius_server = radius_server
    end

    if !radius_secret.nil?
      @radius_secret = radius_secret
    end
  end

  def run
    # check if already running
    if @pid > 0 and is_running
      stop
    end

    # for stdout pipe redirection thread, kill if running
    if !@thread.nil?
      Thread.kill(@thread)
      @thread = nil
    end

    puts "Start the Radius Client process"

    # cmd = "./radius_client.rb"
    cmd = "ruby #{__dir__}/radius_client.rb"
    if !@radius_server.nil?
      cmd += " --server #{@radius_server}"
    end

    if !@radius_secret.nil?
      cmd += " --secret #{@radius_secret}"
    end

    puts "Starting RADIUS client: '#{cmd}'"

    # create IO pipe reader/writer to redirect STDOUT from spawned process to the state machine
    reader, writer = IO.pipe

    @pid = Process.spawn(cmd, chdir: __dir__, out: writer, err: writer)
    Process.detach(@pid)

    # this thread reads the output of the above spawned process and redirects it to STDOUT
    writer.close
    @thread = Thread.new do
      loop do
        begin
          begin
            lines = reader.read_nonblock(4096)
          rescue EOFError # EOF Error is when process is killed.
            @thread = nil
            Thread.exit
          end

          lines.split("\n").each do |line|
            line = line.strip
            if line.length > 0
              print "[RADIUSCLIENT #{@pid}] '#{line}'\n"
            end
          end
        rescue IO::WaitReadable
          # IO.select([io])
          # retry
        end
        sleep(0.1)
      end
    end

    print "Start radius client: #{@pid}\n"
    @state = PROCESS_STATES::RUN
  end

  def stop
    if @pid > 0 and is_running
      puts "Stopping radius client: #{@pid}."
      cmd = "kill -9 " + @pid.to_s
      `#{cmd}`
      @pid = 0
    end
    @state = PROCESS_STATES::DOWN
  end

  def get_pid
    pid
  end
end

#################################################################
#
# State: A class for state representation and management
#
#################################################################
class State
  def initialize(state, sleep_time = DEFAULT_SLEEP)
    @my_state = state
    @changed = true
    @last_run_time_ms = 0
    @sleep_time_secs = sleep_time # in seconds
    @pause_between_state_change = false
  end

  def update(state, should_pause = false)
    if state != @my_state
      @my_state = state
      @changed = true
      @pause_between_state_change = should_pause
    end
  end

  def get
    @my_state
  end

  def is_changed
    if @changed
      @changed = false
      return true
    end
    false
  end

  def should_sleep
    @pause_between_state_change
  end

  def now_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
  end

  def set_poll_time(poll_time_secs)
    # Make sure passed param can be converted into an integer. (i.e. catch NIL, etc)
    poll_time_secs = begin
      Integer(poll_time_secs)
    rescue
      false
    end
    if poll_time_secs === false
      return
    end

    # We never want poll time to be less than 0.
    if poll_time_secs == 0
      return
    end

    @sleep_time_secs = poll_time_secs
  end

  def sleep
    sleep_time_ms = (@sleep_time_secs * 1000) - (now_ms - @last_run_time_ms)
    sleep_time_ms = sleep_time_ms.round

    if sleep_time_ms > 0
      puts "sleeping #{sleep_time_ms} ms"
      Kernel.sleep(sleep_time_ms.to_f / 1000)
    end
    @last_run_time_ms = now_ms
  end
end

module MESSAGES
  HELLO = "/hello"
end

#################################################################
#
# Default Config - a template for hostapd configurations
#
#################################################################
DEFAULT_CONFIG = {country_code: "US",
                  interface: "dummy",
                  driver: "nl80211",
                  ssid: "cloudwifi",
                  ignore_broadcast_ssid: 0,
                  ieee80211d: 1,
                  hw_mode: "g",
                  ieee80211n: 1,
                  require_ht: 1,
                  ieee80211ac: 1,
                  channel: 11,
                  wpa: 2,
                  auth_algs: 1,
                  wpa_key_mgmt: "WPA-PSK",
                  rsn_pairwise: "CCMP",
                  wpa_pairwise: "CCMP",
                  wpa_passphrase: "clouddefault",
                  wmm_enabled: 1,
                  ctrl_interface: "/var/run/hostapd",
                  ctrl_interface_group: 0,
                  wpa_psk_file: "/tmp/hostapd.wpa_pmk_file"}

# Default rate for time between hellos (seconds)
DEFAULT_RATE = 5
# time between station list (seconds)
STATION_SCAN_TIME = 30

# Get our gateway address
def get_gateway
  gw = `ip route | awk '/default/{print $3; exit}'`.chomp.presence || nil
  begin
    r = IPAddr.new gw
  rescue IPAddr::InvalidAddressError
    puts "BAD Gateway"
    return nil
  end
  r.to_s
end

# Get ethernet MAC address
def get_mac_address
  platform = RUBY_PLATFORM.downcase
  mac = `ip link show dev eth0 | awk '/link/{print $2}'`
  mac.chomp
end

def get_os
  os = `uname -r`
  os.strip
end

def get_piglet_version
  cmd = `apt info piglet 2>/dev/null`

  if cmd =~ /Version:\s+(.+)/
    return $1.strip
  end
  nil
end

def get_cpu_info
  serial = `awk '/Serial/{print $3}' /proc/cpuinfo`.chomp
  model = `awk '/Model/{$1=$2=""; print $0}' /proc/cpuinfo`.chomp.lstrip
  {"serial" => serial, "model" => model}
end

def get_wlan_list
  output = `iw dev`
  iwDev = output.split("\n")
  interfaces = []
  i = 0
  while i < iwDev.length
    if iwDev[i] =~ /^phy#(\d)/
      phy = "phy" + $1
      i += 1
      while i < iwDev.length and !(iwDev[i] =~ /^phy#\d/)
        if iwDev[i] =~	/\s+Interface (wlan\d)/
          interface = $1
        end
        if iwDev[i] =~ /addr ([a-fA-F0-9:]{17}|[a-fA-F0-9]{12})/
          mac = $1
        end
        if iwDev[i] =~ /.+type (\w+)/
          type = $1
        end
        if iwDev[i] =~ /.+txpower ([\d.]+)/
          txpower = $1
        end
        i += 1
      end
      if type == "managed" or type == "AP"
        interfaces.append({wlan: interface, phy: phy, mac: mac, txpower: txpower})
      end
    end
  end
  interfaces
end

# Gather all the information about wifi hardware
def gather_wlan_info
  interfaces = get_wlan_list
  wlans = []
  interfaces.each { |i_hash|
    bands = get_wlan_bands(i_hash[:phy])
    i_hash = i_hash.merge(bands)
    wlans.append(i_hash)
  }
  wlans
end

# Get modes and channel list of a given wifi device
def get_wlan_bands(phy)
  iwlist = `iw list`
  # Find the interface
  lines = iwlist.split(/\n+/)
  i = 0
  while i < lines.length and !lines[i].include? "Wiphy " + phy
    i += 1
  end
  i += 1

  # find each band
  bands = {}
  while i < lines.length and !lines[i].include? "Wiphy "
    if lines[i] =~ /^\s*Band\s(\d):.*/
      band = $1

      i += 1
      channels = []
      caps = []
      freqs = []
      power = []
      # Get capabilities for a band
      while i < lines.length and !(lines[i] =~ /^\s*Band (\d):.*/) and !lines[i].include?("Supported commands:") and !lines[i].include?("Wiphy ")
        # Find capabilities
        if lines[i].include?("Capabilities: 0x")
          i += 1
          while !lines[i].include?("Maximum") and lines[i] =~ /^\s+(\w.+)$/
            caps.push($1)
            i += 1
          end
        end

        if lines[i].include?("Frequencies")
          i += 1
          while lines[i] =~ /^\s+\* \d+\sMHz/
            if !lines[i].include?("disabled") and !lines[i].include?("radar") and !lines[i].include?("no IR")
              if lines[i] =~ /^\s+\* (\d+)\sMHz\s\[(\d+)\]\s+\(([\d.]+)/
                channels.push($2.to_i)
                freqs.push($1)
                power.push($3)
              end
            end
            i += 1
          end
        end
        if i < lines.length and !(lines[i] =~ /^\s*Band\s(\d):.*/) and !lines[i].include?("Wiphy ")
          i += 1
        end
      end
      # Finsh up a band
      bands["band" + band] = {channels: channels, frequencies: freqs, power: power, capabilities: caps}

    end
    if i < lines.length and !(lines[i] =~ /^\s*Band\s(\d):.*/) and !lines[i].include?("Wiphy ")
      i += 1
    end
  end
  bands
end

# Get the maximum interface number of the wlans
def get_max_wlan
  output = `ip link show`

  interfaces = []
  i = 0
  max_index = -1
  max_interface = "none"
  output.each_line do |line|
    # look for lines with wlan in it. Index of interface is in $1, index of wlan is in $2
    next unless line =~ /^([0-9]+):\swlan([0-9]+):/

    index = $2.to_i
    if index > max_index
      max_index = index
      max_interface = "wlan#{index}"
    end
  end
  max_interface
end

# Get modes and channel list
def get_hw_info
  iwlist = `iw list`
  max_if = "phy0"

  # find max interface
  iwlist.each_line do |line|
    if /Wiphy/.match?(line)
      i = line =~ / phy/
      if i
        itf = line[i + 1..-1].chomp
        max_if = (max_if > itf) ? max_if : itf
      end
    end
  end
  # Find the interface
  lines = iwlist.split(/\n+/)
  i = 0
  while i < lines.length and !lines[i].include? max_if
    i += 1
  end
  i += 1

  # Find the frequencies
  # g is for channels under 15,
  # a for other channels (for now)
  chan_a = []
  chan_g = []
  while i < lines.length and !lines[i].include? "Wiphy phy"

    # ignore radar for now
    if !lines[i].include? "radar" and !lines[i].include? "disable"
      chan_info = lines[i].scan(/(\s\*\s\d+\sMHz\s\[)(\d+)/)

      if chan_info.instance_of? Array and chan_info.any?
        chan = chan_info[0][1].to_i
        if chan <= 14
          chan_g.push(chan)
        else
          chan_a.push(chan)
        end
      end
    end
    i += 1
  end
  {g: chan_g, a: chan_a}
end

###########################################################
# get_stations - given an interface return a list of stations
# Including all information available.  Minimum is MAC addresses
############################################################
def get_stations(interface, channel)
  @cmd = "iw dev #{interface} station dump"
  # puts @cmd
  @station_list = `#{@cmd}`
  @lines = @station_list.split("\n")
  @stations = {}
  @station = {}
  @mac = ""
  i = 0
  while i < @lines.length
    # puts @lines[i]
    # if this is a new station, save the old
    if @lines[i] =~ /Station\s/ and @mac.length > 0
      @stations[@mac] = @station
      @station = {}
      @mac = ""
    end
    if @lines[i] =~ /Station\s(.+)\s\(on (.+)\)/
      @mac = $1
      @station["interface"] = $2
      @station["channel"] = channel
    end
    if @lines[i] =~ /\s(.+):\s(.+)/
      @station[$1] = $2.strip
    end
    i += 1
  end
  if @mac.length > 0
    @stations[@mac] = @station
  end
  @stations
end

# Given a list of interfaces gather all station (client) information
# Into a hash
# Send a hash of wlans and channels.
def gather_station_info(interface_channels, connection_states, hostapd_procs, pmks)
  # Get the current connection states from the connetion log
  update_connections(connection_states,pmks)

  @all_stations = {}
  # Add in all disconnected stations if we were already assocated
  # If something has reconnected, it will be over written by the code below
  @local_time = Time.new
  connection_states.each { | mac, station |
  	  # delete old entries
      if station["event"] == "disassoc"
      	if (@local_time-station["local_time"]) > 5
      		connection_states.delete(mac)
      	else
        	@all_stations[mac] = station
      	end
      else
      	station["local_time"] = @local_time
      end
  }
  interface_channels.each { |wlan, channel|
    # get the stations for a given wlan
    @stations = get_stations(wlan, channel)
    # puts "STATIONS! #{@stations}"
    # Merge results with latest connection state
    @stations.each { |mac, station|
      station_state = connection_states[mac]
      # puts "STATION STATE #{mac} #{station_state}"
      # puts "STATION DATA #{@stations[mac]}"
      if !station_state.nil?
        @stations[mac] = @stations[mac].merge(station_state)
      end
      @stations[mac]["ssid"] = hostapd_procs[@stations[mac]["interface"]].ssid
      if @stations[mac]["associated"] == "yes"
      	@stations[mac]["event"]="assoc"
      end
      # puts " @pmk_to_user_id #{ @pmk_to_user_id}"
      # puts "USER: #{@pmk_to_user_id[@stations[mac]["pmk"]]}"
      @stations[mac]["user_id"] = @pmk_to_user_id[ @stations[mac]["pmk"]]
    }

    @all_stations = @all_stations.merge(@stations)

     #puts "STATIONS: #{ @all_stations }"

    # Clear connection states for stations no longer present
    # connection_states.keys.each { | mac |
    #  if not @all_stations.key? mac
    #    connection_states.delete(mac)
    #    puts "Delete #{mac} from connection states"
    #  end
    # }
  }
  @all_stations
end

#######################################################################
# read connections log and clear it
#######################################################################
CONNECTION_LOG = "/tmp/connections.log"

def update_connections(connections,pmks)
  begin
    File.open(CONNECTION_LOG).each do |line|
      puts "CONNECTION: #{line}"
      connection = JSON.parse(line)
      if connection.key? "mac"
        mac = connection["mac"].downcase
        connection["local_time"]=Time.new
        connections[mac] = connection
        #connections[mac]["maxdev"] = pmks[conn["pmk"][maxdev]]
      end
    end
    #connections.each do |mac,conn|
    #  conn["maxdev"] = pmks[conn["pmk"][maxdev]]
    #end
    # Clear the file
    puts "CLEAR Connection FILE"
    `rm #{CONNECTION_LOG}`
    # File.open(CONNECTION_LOG,'w') {|file| file.truncate(0) }
  rescue
    puts "ERROR in deleting connections.log file"
    # nothing else to do here
  end
  # Clear the file
  #puts "CLEAR FILE"
  #`rm #{CONNECTION_LOG}`
  # File.open(CONNECTION_LOG,'w') {|file| file.truncate(0) }
rescue
  puts "ERROR in processing connections.log file"
  # nothing else to do here
end

#######################################################################
# Local AP scanning and Auto channel setting code
#######################################################################
# Channels that overlap. we only use 1, 6, 11
OVERLAPPING_CHANNELS = {2 => [1, 6], 3 => [1, 6], 4 => [1, 6], 5 => [1, 6], 7 => [6, 1],
                        8 => [6, 11], 9 => [6, 11], 10 => [6, 11], 12 => [11, 14],
                        13 => [11, 14]}

#######################################################################
# overlap_channels - return the real channels this channel affect
#######################################################################
def overlap_channels(channel)
  if OVERLAPPING_CHANNELS.key?(channel)
#    print "Fucking overlapping channel: ", channel, "\n"
    OVERLAPPING_CHANNELS[channel]
  else
    [channel]
  end
end

#######################################################################
# get_ap_list - Get a list of APs visible as a hash over AP addresses
# interface is the interface to use to do the scan
#######################################################################
def scan_for_aps(interface)
  # First let's make sure the interface is up
  cmd = "ifconfig #{interface} up"
  print "Bringing up interface: #{cmd}\n"
  `#{cmd}`
  # puts "After bringing interface up..."

  @ap_list = `iw dev #{interface} scan`
  @lines = @ap_list.split("\n")
  @ap_data = {}
  @address = ""
  @ssid = ""
  @channel = ""
  @signal = ""
  @frequency = ""
  @ht_width = ""
  @ht_protection = ""
  i = 0
  while i < @lines.length
    if @lines[i] =~ /BSS (.+)\(/
      if @address != ""
        # Convert overlapping channels to actual channel(s)
        @cell = {"SSID" => @ssid, "channel" => @channel,
                 "frequency" => @frequency, "ht_width" => @ht_width,
                 "signal" => @signal, "ht_protection" => @ht_protection}
        @ap_data[@address] = @cell

        # Clear out for next
        @address = ""
        @ssid = ""
        @channel = ""
        @signal = ""
        @frequency = ""
        @ht_width = ""
        @ht_protection = ""
      end
      @address = $1
    end
    if @lines[i] =~ /\sSSID: (.+)/
      @ssid = $1
    end
    if @lines[i] =~ /\sprimary channel: (\d+)/
      @channel = $1.to_i
    end
    if @lines[i] =~ /\sfreq: (.+)/
      @frequency = $1
    end
    if @lines[i] =~ /\ssignal: (.+) dBm/
      @signal = $1.to_f
    end
    if @lines[i] =~ /\s* STA channel width: (.+)/
      @ht_width = $1
    end
    if @lines[i] =~ /\s* HT protection: (.+)/
      @ht_protection = $1
    end
    i += 1
  end
  if !@ap_data.key?(@address)
    @cell = {"SSID" => @ssid, "channel" => @channel,
             "frequency" => @frequency, "ht_width" => @ht_width,
             "signal" => @signal, "ht_protection" => @ht_protection}
    @ap_data[@address] = @cell
  end
  if @address != ""
    @ap_data
  end
end

#######################################################################
# select channel - find a channel for a interface
# interface - the channel to select for. A scan will be done on this
#             interface, so the interface MUST BE down (no hostapd running)
# band - the band to use (G or A)
# channels - the list of channels the wifictlr says we can choose from
#
#######################################################################
def select_channel(interface, channels, channel)
  if channels.is_a? String
    channels = string_to_array(channels)
  end

  if channels[0].is_a? String
    channels.map!(&:to_i)
  end
  # Check for corner cases
  if channels.length == 0
    return channel
  end
  if channels.length == 1
    return channels[0]
  end

  @avail_channels = channels.to_set

  @scan = scan_for_aps(interface)
  # print @scan,"\n"
  if @scan.nil?
    print "No APs found, choosing a random station\n"
    return channels.sample
  end
  # create a hash of ap channels, and the signal strengths
  # If the channel already exists with a stronger signal, ignore weaker
  @channel_levels = {}
  @used_channels = Set[]
  @scan.each do |mac, info|
    # convert overlapping channels into two real channels
    @chans = overlap_channels(info["channel"])
    @chans.each do |chan|
      @used_channels.add(chan)
      if @channel_levels.key?(chan)
        if @channel_levels[chan] < info["signal"]
          @channel_levels[chan] = info["signal"]
        end
      else
        @channel_levels[chan] = info["signal"]
      end
    end
  end
  # puts @channel_levels
  # print "In use:", @used_channels, "\n"
  @unused = @avail_channels - @used_channels
  # print "unused:", @unused, "\n"
  if @unused.length > 0
    return @unused.to_a.sample
  end
  puts "No unused channels, finding best"

  # Scan through channels to find the one with the weakest signal
  @least_channel = 0
  @least_signal = 0
  @channel_levels.each do |chan, sig|
    if @avail_channels.include?(chan) and sig < @least_signal
      @least_signal = sig
      @least_channel = chan
    end
  end
  @least_channel
end

#################################################################
#
# wifictlr message functions
# These function create message to push to the
# pifi wifictlr contoller endpoint
#
#################################################################

# post message to wifictlr. Expect JSON in return.
def send_cloud_request(wifictlr, endpoint, postdata)
  body = postdata.to_json

  url = "http://#{wifictlr}:#{PORT}/api/v1/wificlients/#{endpoint}"
  # puts "url: #{url}"
  # puts "SEND: #{body}"
  header = {"Content-Type" => "application/json"}

  response_error = {
    status: "httperror",
    error: nil
  }

  begin
    result = Client.post(url,
      body: body,
      headers: header,
      timeout: 5)         # timeout is in seconds
  rescue HTTParty::Error, SocketError => e
    response_error[:error] = "HTTParty::Error: #{e.messages} "
    return response_error
  rescue => error
    response_error[:error] = "HTTParty::Error: #{error}"
    return response_error
  end

  if result.code != 200 and result.code != 201
    response_error[:error] = "HTTParty: non 200 error: #{result.code}"
    return response_error
  end

  begin
    result.parsed_response
  rescue JSON::ParserError => e
    response_error[:error] = "JSON::Error: #{e.messages} "
    return response_error
  end

  result = result.parsed_response["json"]
end

# get message to wifictlr. Expect JSON in return.
def get_cloud_request(wifictlr, endpoint, postdata)
  body = postdata.to_json

  url = "http://#{wifictlr}:#{PORT}/api/v1/wificlients/#{endpoint}"

  puts "url: #{url}"
  header = {"Content-Type" => "application/json"}

  response_error = {
    status: "httperror",
    error: nil
  }

  begin
    result = Client.get(url,
      body: body,
      headers: header,
      timeout: 5)         # timeout is in seconds
  rescue HTTParty::Error, SocketError => e
    response_error[:error] = "HTTParty::Error: #{e.messages} "
    return response_error
  rescue => error
    response_error[:error] = "HTTParty::Error: #{error}"
    return response_error
  end

  if result.code != 200 and result.code != 201
    response_error[:error] = "HTTParty: non 200 error: #{result.code}"
    return response_error
  end

  begin
    result.parsed_response
  rescue JSON::ParserError => e
    response_error[:error] = "JSON::Error: #{e.messages} "
    return response_error
  end

  result = result.parsed_response["json"]
  # puts "send_loud_request result######: #{r}"
end

# Send a hello message to the wifictlr
def send_cloud_hello_mesg(wifictlr, mac)
  wlan = get_max_wlan
  os = get_os

  cpu = get_cpu_info

  # get radio info
  channels = get_hw_info.to_json
  wlans = gather_wlan_info
  version_str = MAJOR.to_s + "." + MINOR.to_s + "." + REVISION.to_s
  puts "VERSION: #{version_str}"
  @my_ip_add = `hostname -I | awk '{print $1}'`.chomp
  body = {mac: mac,
          version: version_str,
          wlans: wlans,
          os: os,
          model: cpu["model"],
          serial: cpu["serial"],
          ipaddress: @my_ip_add}

  print "Hello: ", body.to_json, "\n"
  send_cloud_request(wifictlr, "hello", body)
end

# Send a config message to the wifictlr
def send_cloud_conf_mesg(wifictlr, mac, start)
  config = {mac: mac,
            start: start}
  # config_hashes: conf_hashes,
  # pmk_hash: pmk_hash
  print "Config request:", config.to_json, "\n"

  result = send_cloud_request(wifictlr, "get_config", config)
  #  result = send_cloud_request(wifictlr, "jsontests/1", config)
  print "Config results:", result.to_json, "\n"
  result
end

# Send an alivemessage to the wifictlr
def send_cloud_alive_mesg(wifictlr, mac, channels, uptime)
  alive = {mac: mac,
           # config_hashes: conf_hashes,
           # pmk_hash: pmk_hash,
           channels: channels,
           uptime: uptime}
  print "Alive request:", alive.to_json, "\n"

  result = send_cloud_request(wifictlr, "alive", alive)
  print "Alive results:", result.to_json, "\n"
  result
end

# Send an wireless clients message to the wifictlr
def send_cloud_clients_mesg(wifictlr, clients)
  send_cloud_request(wifictlr, "update_wireless_clients", clients)
end

# Class to allow unchecked https
class Client
  include HTTParty

  # verify:false disables SSL cert checking
  default_options.update(verify: false)
end

#################################################################
#
# write pmk file - write a pmk list recieved from wifictlr to a file
#
#################################################################
def write_pmk(pmks)
  # puts "PMK:",pmks
  # Write out the new file
  File.open(PMK_FILE, "w") { |f|
    # f.write("# Hash: "+hash+"\n")
    f.write("# Warning - This file is auto generated.  Do not modify\n")
    pmks.each do |pmk_entry|
      if pmk_entry.key?("user_id") and pmk_entry.key?("pmk")
        f.write(" pmk=" + pmk_entry["pmk"] + "\n")
        @pmk_to_user_id[pmk_entry["pmk"]] = pmk_entry["user_id"]
      elsif pmk_entry.key?("user_id") and pmk_entry.key?("vlan_id") and pmk_entry.key?("pmk")
        f.write(" vlan_id=" + pmk_entry["vlan_id"].to_s + " pmk=" + pmk_entry["pmk"] + "\n")
      elsif pmk_entry.key?("vlan_id") and pmk_entry.key?("pmk") # No Login/account association (Normal for PSK WLAN)
        f.write("vlan_id=" + pmk_entry["vlan_id"].to_s + " pmk=" + pmk_entry["pmk"] + "\n")
      else
        puts "Bad PMK entry: #{pmk_entry}"
      end
    end
  }
  # puts "PMK to USER: #{ @pmk_to_user_id}"
end

#################################################################
#
# create_pmk_hash - Create a hash of pmks and the corrsponding data
#
#################################################################
def create_pmk_hash(pmks)
    my_pmks={}
	pmks.each do |pmk_entry|
		my_pmks[pmk_entry["pmk"]] = {:userid=>pmk_entry["user_id"], :maxdev =>pmk_entry["maxdev"], :upmax =>pmk_entry["upmax"], :downmax =>pmk_entry["downmax"] }
	end	
	return my_pmks
end

#################################################################
#
# write config - write a new hostapd.conf from information from wifictlr
# Returns static VLAN number or -1, ssid or "", channel or ""
#
#################################################################
def write_config(config, hostapd_procs)
  print "Configuration sent: ", config, "\n"
  @chan_list = []
  @auto_channel = 0
  new_config = DEFAULT_CONFIG.dup
  channel = false
  static_vid = -1
  ssid = nil

  config.each do |key, value|
    case key
    when "ssid"
      new_config[:ssid] = value
      @ssid = value
    when "interface"
      new_config[:interface] = value
      @interface = value

    when "channel"
      if !value.nil?
        new_config[:channel] = value
        @auto_channel = value
      end

    when "hw_mode"
      if !value.nil?
        new_config[:hw_mode] = value.downcase
      end

    when "channel_24"
      if !value.nil?
        new_config[:channel] = value
        channel = true
        new_config[:hw_mode] = "g"
      end

    when "channel_5"
      if !channel and !value.nil?
        new_config[:channel] = value.to_s
        channel = true
        new_config[:hw_mode] = "a"
      end

    when "open"
      # if OpenSSID (no PSK) delete all WPA attributes
      if !value.nil? && value == true
        new_config.delete(:wpa)
        new_config.delete(:auth_algs)
        new_config.delete(:wpa_key_mgmt)
        new_config.delete(:rsn_pairwise)
        new_config.delete(:wpa_pairwise)
        new_config.delete(:wpa_passphrase)
        new_config.delete(:wpa_psk_file)
      end

    when "open_vid"
      if !value.nil?
        static_vid = value
      end

    when "channel_list"
      if !value.nil?
        @chan_list = value
      end

    else
      if value.nil?
        value = "nil"
      end
      print "Ignoring: " + key + " = " + value.to_s + "\n"
    end
  end

  if !@ssid.nil? and !@interface.nil?
    hostapd_procs[@interface].set_ssid(@ssid)
  end

  # We have a config, now we need to pick a channel if we got a list of channels
  print "########################## Auto Channel selection ################\n"
  if @chan_list.length > 0
    print "candidate channels:", @chan_list, "\n"
    # Stop the wlan for channel scan
    if !hostapd_procs.nil? and hostapd_procs.key?(@interface) and hostapd_procs[@interface].is_running
      hostapd_procs[@interface].stop
    end
    @auto_channel = select_channel(@interface, @chan_list, @auto_channel)
    print "Auto channel: ", @auto_channel, "\n"
    new_config[:channel] = @auto_channel
  end

  print "New Config", new_config, "\n"
  # Write out the new file
  config_file = "/tmp/hostapd." + new_config[:interface] + ".conf"
  File.open(config_file, "w") { |f|
    # f.write("# Hash: "+hash+"\n")
    f.write("# Warning - This file is auto generated.  Do not modify\n")
    f.write("ctrl_interface=/tmp/hostapd\n")
    new_config.each do |key, value|
      if !value.nil?
        f.write(key.to_s + "=" + value.to_s + "\n")
      end
    end
  }
  [static_vid, ssid, @auto_channel]
end

# Delete /tmp/hostap.conf/
# These won't be needed once we put file in ram dick
# TODO
def clear_ap_config
end

# delete /tmp/hostapd.wpa_pmk_file
# TODO
def clear_pmk_file
end

#################################################################
#
# Process the passed poll wait time
#
#################################################################
def process_wait_time(wait, data)
  if data.nil? then return nil end

  if data.key?("poll_time")
    new_wait = result["poll_timer"].to_i
    if new_wait.is_a? Integer
      wait = new_wait
      print "New wait time: ", wait, "\n"
      wait = 5 # force to 5 for testing
    end
  end
  wait
end

#################################################################
#
# WiFiState Machine
# Main routine for managing pifi AP states for multiple interfaces
# This process runs forever, managing system states and keeeping
# the system in regular communication with the wifictlr
# This process allows the local device to be the active agent
# in managing a WiFi device, while the wifictlr is a passive partner
# responding to WiFi messages
#
#################################################################
@should_run = true
def pifi_management
  # A place to store our current channel to wlan association
  @channels = {}
  # Used to keep the uptime in seconds
  @uptime = 0
  # stores the time the AP started, 0 means not started
  @start_time = 0
  # The hash of the config currently running on the device
  @config_digest = ""
  # kill hostapd, wlanbridge and radius client by name
  `killall hostapd`
  # `pkill -f wlanbridge`
  # `pkill -f radius_client.rb`

  # sleep to allow system to recover from killing hostapd and wlanbridge.
  sleep(1)

  # The latest config and pmk hash
  # config_hashes = Hash.new
  # pmk_hash = "FFFFFFFFFFFF"
  pmk_file = nil
  new_pmk = false

  # Create objects to manage processes
  hostapd_procs = {}

  interfaces = get_wlan_list
  interfaces.each do |interface|
    print "New interface ", interface[:wlan], "\n"
    hostapd_procs[interface[:wlan]] = Hostapd_instance.new(interface[:wlan])
  end
  # wlanbridge_proc = Wlanbridge_instance.new
  # radiusclient_proc = Radiusclient_instance.new()

  # Get our local MAC and controller address
  controller_ip = CONTROLLER
  # controller_ip = get_gateway
  puts "IP: " + controller_ip
  mac = get_mac_address

  # Get my ip address
  @my_ip_add = `hostname -I | awk '{print $1}'`.chomp
  puts "My IP: #{@my_ip_add}"

  # radiusclient_proc.set_params(radius_server: controller_ip)

  # time to wait between polls
  wait = DEFAULT_RATE

  # Start by wiping the configeration and pmk file
  clear_ap_config
  clear_pmk_file

  # State is "START" unless we don't know our gateway (wifictlr controller)  yet.
  state = if controller_ip.nil?
    State.new(STATES::WAITGW)
  else
    State.new(STATES::START)
  end

  # List of current active interfaces
  interfaces = []

  # Set time for station scan to now
  @next_station_scan = Time.now

  # Failure counter
  response_failures = 0

  # Process Restart Counters for HostAPD, WLANBridge and RadiusClient
  proc_restart_failures = 0

  # Set start to 1 so we get a complete configuration
  start = 1

  # Start the state machine
  while @should_run

    # Sleep until next time unless it is a new state
    # TODO: A SYNC from wifictlr needs to end sleep
    if !state.is_changed
      # puts "No state change recorded"
      state.sleep
    elsif state.should_sleep
      state.sleep
    end

    # Update timestamp on pifi.pid for overseerer to make sure this is still running.
    `touch /run/pifi.pid`

    # sleep_secs = state.should_sleep()
    # puts "Kernel.sleep(#{sleep_secs})"
    # if sleep_secs
    #   puts "Kernel.sleep(#{sleep_secs})"
    #   Kernel.sleep(sleep_secs)
    # end

    # The WiFi has started, and is saying hello to wifictlr
    case state.get

    # Wait for the wifictlr gateway address to be available
    # In case Pi starts before wifictlr
    when STATES::WAITGW
      1.times do
        puts "WAITGW State"
        controller_ip = CONTROLLER
        if controller_ip.nil?
          # No controller IP yet, wait 10 seconds
          state.set_poll_time(10)
          puts "Waiting for Controller IP: #{controller_ip}"
        else
          state.update(STATES::START)
          puts "Found controller IP: " + controller_ip
        end
      end # end of 1.times do

    when STATES::START
      1.times do # Loop once, so we can break out if needed.
        puts "START State"
        @start_time = 0
        proc_restart_failures = 0

        result = send_cloud_hello_mesg(controller_ip, mac)
        puts "Reply:", result

        if result.nil? then break end

        wait = process_wait_time(wait, result)

        #        if result['status'] == 'approved'
        if result["status"] == "approved" or result["status"] == "registered"
          state.update(STATES::CONFIG)
        elsif result["status"] == "registered" # registered within controller but not approved. Stay in START state

        else # unknown response status
          puts "Bad HTTP response #{result}  from #{controller_ip} "
          break
        end

        poll_timer = result["poll_timer"]
        # puts "setting poll timer to #{poll_timer} secs."
        state.set_poll_time(poll_timer)
      end # end of 1.times do

    # The WiFi is asking for a configuration
    # The WiFi will send the hostapd.conf hashes and the pmk_hash.
    # The wifictlr should return all the configs.
    # This will only apply the configs if they have changed.
    when STATES::CONFIG

      1.times do # Loop once, so we can break out if needed.
        puts "CONFIG state"
        @start_time = 0
        static_vids = {}
        result = send_cloud_conf_mesg(controller_ip, mac, start)
        wait = process_wait_time(wait, result)

        if result.nil?
          response_failures += 1
          puts "nothing returned from wifictlr, retries: #{response_failures}"
          if response_failures > CLOUD_RETRIES
            puts "#{CLOUD_RETRIES} falures, disabling WiFi"
            state.update(STATES::DISABLING)
            response_failures = 0
          end
          break
        end

        status = result["status"]
        if status != "success"
          puts "config response status '#{status}'. Putting PIFI into Disabling state"
          state.update(STATES::DISABLING)
          break
        end

        # Updates the config hash to reflect the most recent config file.
        @config_digest = result["configdigest"]
        puts "Received configuration hash: #{@config_hash}"

        # set radius secret
        # if !result["radius_secret"].nil?

        #  puts "@@@@ Setting Radius Secret: " + result["radius_secret"]
        #  radiusclient_proc.set_params(radius_secret: result["radius_secret"])
        # end

        pmk = result["pmk"]
        @pmks = create_pmk_hash(pmk)
        puts "PMKS: #{@pmks}"

        new_pmk = false
        # optionally write a new pmkile
        #        if ((not pmk.nil?) and (pmk_hash != result["pmk_hash"]))
        if !pmk.nil?
          # pmk_hash = result["pmk_hash"]
          write_pmk(pmk)
          new_pmk = true
          puts "*** New PMK File"
        end

        active_interfaces = []
        devices = result["radios"]
        print "DEVICES: ", devices, "\n"
        interface_change = false
        # Go through interfaces
        # Write a new hostapd.wlanX.conf file for each config where the hash differs,
        # Start AP for new configs
        # Restart AP if config changed
        # Stop device if no longer enabled.
        hostapd_procs.each do |interface, hostapd_proc|
          # Find a matching wlan for this proc
          device = devices.select { |x| x["wlan"] == interface }.first
          if !device.nil?
            if !device["wlan"].nil? and !device["config"].nil?
              # config_hash = device["config_hash"]
              wlan = device["wlan"]
              mode = device["config"]["mode"]
              config = device["config"]
              # If the mode is "AP" we need to set up this interface.  First check the config_hash for a change
              if mode == "AP"
                print "FOUND AP:", wlan, "\n"
                if hostapd_proc.is_running
                  hostapd_proc.stop
                end
                sleep(2)
                ap_config = config["hostapd"]
                active_interfaces.push(wlan)
                # if config_hashes[wlan] != config_hash
                interface_change = true
                static_vid, ssid, chan = write_config(ap_config, hostapd_procs)
                # Save channel to report to wifictlr
                @channels[interface] = chan
                # If static vid in config, use that
                if static_vid > 0
                  static_vids[wlan] = {static_vid: static_vid, ssid: ssid}
                  puts "VIDS[#{ssid}]:", static_vids
                end
                # config_hashes[wlan] = config_hash
                print "*** New Config for ", wlan, "\n"
                # hostapd_proc.run_or_hup(WLAN_STATES::AP)
                hostapd_proc.set_to_start
                start = 0
                if new_pmk
                  # If the pmks change, we must reload
                  puts "reloading pmks for #{wlan}"
                  cmd = "hostapd_cli -i #{wlan} reload_wpa_psk"
                  result = `#{cmd}`.chomp
                  if result != "OK"
                    puts "Reload pmks failed, restarting hostapd for #{wlan}"
                    # hostapd_proc.run_or_hup(WLAN_STATES::AP)
                    hostapd_proc.set_to_start
                  end
                else
                  print "Not a NEW Config for ", wlan, "\n"
                end
              elsif mode == "OFF"
                # if config_hashes[wlan] != config_hash
                #  config_hashes[wlan] = config_hash
                print "Stop: ", interface, "\n"
                interface_change = true
                # if hostapd_proc.is_running
                hostapd_proc.stop
                # end
              else
                print "Unknown radio mode: ", mode, "\n"
              end
            end
          end
        end
        # Restart wlanbridge if an interface changed
        #if interface_change or !wlanbridge_proc.is_running
        #  print "INTERFACE CHANGE!", "\n"
        #  wlanbridge_proc.stop
        #  sleep(1)
        #  wlanbridge_proc.run(active_interfaces, static_vids)
        #end

        # Start Radius Client
        # if !radiusclient_proc.is_running
        #  radiusclient_proc.run()
        # end
        @start_time = Time.now
        state.update(STATES::RUN)

        # Start the hostaps
        hostapd_procs.each do |interface, hostapd_proc|
          puts "START HOSTAPD: #{interface}:#{hostapd_proc.state}"
          if hostapd_proc.state == WLAN_STATES::WAIT_AP
            hostapd_proc.run_or_hup(WLAN_STATES::AP)
          end
        end
      end # end of 1.times do

    # The WiFi is in a misconfigured state
    when STATES::HEALTH
      puts "HEALTH State"

    # The WiFi is up and running
    when STATES::RUN
      1.times do # Loop once, so we can break out if needed.
        puts "RUN State"

        if proc_restart_failures >= PROC_RESTART_RETRIES
          puts "Excessive ProcRestartFailures: #{proc_restart_failures}."
          state.update(STATES::DISABLING)
          break
        end

        hostapd_procs.each do |interface, hostapd_proc|
          if hostapd_proc.state == WLAN_STATES::AP
            if !hostapd_proc.is_running
              print "hostapd for ", hostapd_proc.wlan, " has unexpectedly stopped", "\n"
              state.update(STATES::DISABLING)
              break
            end
          end
        end
        if state.get != STATES::RUN # HostAPD instance has crashed, break out of RUN case.
          break
        end

        #if !wlanbridge_proc.is_running
        #  puts "wlanbridge has unexpectedly stopped"
        #  state.update(STATES::DISABLING)
        #  break
        #end

        # if not radiusclient_proc.is_running
        #  puts "Radius Client has unexpectedly stopped. Restarting."
        #  radiusclient_proc.run()
        #  proc_restart_failures += 1
        #  break
        # end

        # Reset counter
        proc_restart_failures = 0

        # See if time for next station scan
        if Time.now > @next_station_scan
          @interfaces = hostapd_procs.keys
          @stations = gather_station_info(@channels, @connection_states, hostapd_procs,@pmks)
          @station_report = {"AP" => mac, "Stations" => @stations}
          puts "####################### Stations ###########################"
          puts @station_report.to_json
          result = send_cloud_clients_mesg(controller_ip, @station_report)
          puts "Send stations result: #{result}"
          @next_station_scan = Time.now + STATION_SCAN_TIME
        end

        @uptime = Time.now - @start_time
        result = send_cloud_alive_mesg(controller_ip, mac, @channels, @uptime)
        if result.nil?
          response_failures += 1
          puts "nothing returned from wifictlr, retries: #{response_failures}"
          if response_failures > CLOUD_RETRIES
            puts "#{CLOUD_RETRIES} falures, disabling WiFi"
            state.update(STATES::DISABLING)
            response_failures = 0
          end

        # Check if reboot is requested
        elsif result["action"] == "reboot" #  Time to reboot
          puts "REBOOT!!!!!!!!!"
          `sudo reboot`
        # Check if reboot is requested
        elsif result["action"] == "upgrade" #  Time to reboot
          puts "######################################################################"
          puts "upgrade!!!!!!!!!"
          puts "######################################################################"
          `sudo -u kenyon git stash`
          `sudo -u kenyon git pull`
          `sudo reboot`
        # See if github version check requested
        # elsif (result["action"] == "version") #  check version
        #  gitstatus = `git status`
        #  if gitstatus.include? "up to date"
        #    puts "$$$$$$$$$$UP to date"
        #  else
        #    puts "$$$$$$$$$$New Version"
        #  end

        elsif result["digest"] == @config_digest # nothing needed to be performed

        elsif result["digest"] != @config_digest # we need to switch back to get a new config as we are out of date
          puts "Received update to alive message. Switching to CONFIG state"
          state.update(STATES::CONFIG)
        # elsif result["status"] == "fail" # AP has most likely been disabled.
        else
          puts "Received FAIL to alive message. Disabling Radio"
          state.update(STATES::DISABLING)
        end
      end # end of 1.times do

    # This state disables hostapd
    when STATES::DISABLING
      puts "Disabling hostapd, wlanbridge and radius_client"
      hostapd_procs.each do |interface, hostapd_proc|
        if hostapd_proc.is_running
          hostapd_proc.stop
        end
      end

      #if wlanbridge_proc.is_running
      #  wlanbridge_proc.stop
      #end

      # if radiusclient_proc.is_running
      #  radiusclient_proc.stop()
      # end

      clear_ap_config
      clear_pmk_file

      # Invalidate config/PMK hashes
      # config_hash = "FFFFFFFFFFFF"
      # pmk_hash = "FFFFFFFFFFFF"

      # set back to DEFAULT_RATE seconds and force pause
      state.set_poll_time(DEFAULT_RATE)
      state.update(STATES::START, true)
    end
  end # End of State Machine Loop

  # Cleanup
  hostapd_procs.each do |interface, hostapd_proc|
    print "Stopping hostapd on ", interface, "\n"
    hostapd_proc.stop
  end
  # wlanbridge_proc.stop
  # radiusclient_proc.stop()

  # response = Client.get(mesg)
  # puts response
end
###################################################################################################
###################################################################################################
# Main program entry point
###################################################################################################
###################################################################################################
# Write out our pid for the systemd
mypid = $$
`chmod a+rw /run`
print "My PID:", mypid, "\n"
File.open("/run/pifi.pid", "w") { |f| f.write mypid, "\n" }

# see if any other instances of pifi are running
lockfile = File.new("/tmp/pifi_controller.lock", "w")
ret = lockfile.flock(File::LOCK_NB | File::LOCK_EX)
if ret === false
  puts "Another instance of pifi controller is running. Exiting"
  exit(-1)
end

# catch ctrl+c and terminates hostapd and wlanbridge
trap("INT") {
  puts "CTRL+C Caught, stopping pifi_state_machine"
  @should_run = false
}

# Enable Logging
logging_directory = "/tmp"
FileUtils.mkdir_p logging_directory
# creates up to 10, 10 MB log files
$logger = Logger.new(logging_directory + "/pifi.log", 10, 10 * 1024 * 1024)

$logger.info { "PIFI STATE MACHINE Version #{MAJOR}.#{MINOR}.#{REVISION}" }
$logger.info { "Running Directory: '#{__dir__}/'." }

# Update radios
# update_usb_radios

# Main running loop. In case exception occurrs, log it and continue.
# CTRL+C Trap toggles should_run
while @should_run
  begin
    pifi_management
  rescue Interrupt => e
    puts "Exiting via Interrupt"
    break
  rescue SystemExit => e
    puts "Exiting via SystemExit"
    break
  rescue Exception => exception
    puts "pifi_management threw error: " + exception.inspect
    puts "Backtrace: " + exception.backtrace.inspect
  end
  sleep(1)
end

# Close to flush any remaining log entries
$logger.close
