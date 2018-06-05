# frozen_string_literal: true
# encoding: ASCII-8BIT

require 'set'
require 'protocols/snmp'

module Cisco; end
module Cisco::Switch; end

::Orchestrator::DependencyManager.load('Aca::Tracking::SwitchPort', :model, :force)
::Aca::Tracking::SwitchPort.ensure_design_document!

class Cisco::Switch::SnoopingCatalystSNMP
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    descriptive_name 'Cisco Catalyst SNMP IP Snooping'
    generic_name :Snooping
    udp_port 161

    default_settings({
        building: 'building_code',
        reserve_time: 5.minutes.to_i,

        snmp_options: {
            snmp_version: 1,
            community: 'public'
        }
    })

    def on_load
        # flag to indicate if processing is occuring
        @processing = nil

        @check_interface = ::Set.new
        @reserved_interface = ::Set.new
        self[:interfaces] = [] # This will be updated via query

        on_update

        # Load the current state of the switch from the database
        query = ::Aca::Tracking::SwitchPort.find_by_switch_ip(remote_address)
        query.each do |detail|
            details = detail.details
            interface = detail.interface
            self[interface] = details

            if details.connected
                @check_interface << interface
            elsif details.reserved
                @reserved_interface << interface
            end
        end

        self[:interfaces] = @check_interface.to_a
        self[:reserved] = @reserved_interface.to_a
    end

    def on_update
        # TODO:: Register for trap callback

        self[:name] = @switch_name = setting(:switch_name)
        self[:ip_address] = remote_address
        self[:building] = setting(:building)
        self[:level] = setting(:level)

        @reserve_time = setting(:reserve_time) || 0
        @snooping ||= []
    end

    def connected
        settings = setting(:snmp_options).to_h.symbolize_keys
        settings[:proxy] = Protocols::Snmp.new(self)
        @client = NETSNMP::Client.new(settings)

        query_index_mappings
        schedule.in(10000) { query_connected_devices }
        schedule.every('1m') do
            query_connected_devices
            check_reservations if @reserve_time > 0
        end

        schedule.every('10m') do
            query_index_mappings
        end
    end

    def disconnected
        schedule.clear
    end

    AddressType = {
        0  => :unknown,
        1  => :ipv4,
        2  => :ipv6,
        3  => :ipv4z,
        4  => :ipv6z,
        16 => :dns
    }.freeze

    AcceptAddress = [:ipv4, :ipv6, :ipv4z, :ipv6z].freeze

    BindingStatus = {
        1 => :active,
        2 => :not_in_service,
        3 => :not_ready,
        4 => :create_and_go,
        5 => :create_and_wait,
        6 => :destroy
    }.freeze

    # cdsBindingsEntry
    EntryParts = {
        '1' => :vlan,        # Cisco has made this not-accessible
        '2' => :mac_address, # Cisco has made this not-accessible
        '3' => :addr_type,
        '4' => :ip_address,
        '5' => :interface,
        '6' => :leased_time,    # in seconds
        '7' => :binding_status, # can set this to destroy to delete entry
        '8' => :hostname
    }.freeze

    SnoopingEntry = Struct.new(:id, *EntryParts.values) do
        def address_type
            AddressType[self.addr_type]
        end

        # ignore the first .
        def mac
            self.id.split('.')[1..-1].map { |i| i.to_i.to_s(16).rjust(2, '0') }.join('')
        end

        def ip
            case self.address_type
            when :ipv4, :ipv4z
                self.ip_address.split(' ').map { |i| i.to_i(16).to_s }.join('.')
            else
                nil
            end
        end
    end

    # A row instance contains the Mac address, IP address type, IP address, VLAN number, interface number, leased time, and status of this instance.
    # http://www.oidview.com/mibs/9/CISCO-DHCP-SNOOPING-MIB.html
    # http://www.snmplink.org/OnLineMIB/Cisco/index.html#1634
    def query_snooping_bindings
        return @processing if @processing
        @processing = :query_snooping_bindings
        
        logger.debug "extracting snooping table"

        # Walking cdsBindingsTable
        entries = {}
        @client.walk(oid: "1.3.6.1.4.1.9.9.380.1.4.1").each do |oid_code, value|
            part, entry_id = oid_code[28..-1].split('.', 2)
            next if entry_id.nil?

            entry = entries[entry_id] || SnoopingEntry.new
            entry.id = entry_id
            entry.__send__("#{EntryParts[part]}=", value)
            entries[entry_id] = entry
        end

        # Process the bindings
        entries = entries.values # TODO:: sort based on lease time
        entries.each do |entry|
            interface = @if_mappings[entry.interface]
            next unless interface && @check_interface.include?(interface)

            # TODO
        end
    ensure
        @processing = nil
    end

    # Index short name lookup
    # ifName: 1.3.6.1.2.1.31.1.1.1.1.xx  (where xx is the ifIndex)
    def query_index_mappings
        return @processing if @processing
        @processing = :query_index_mappings

        logger.debug "mapping ifIndex to port names"

        mappings = {}
        @client.walk(oid: "1.3.6.1.2.1.31.1.1.1.1").each do |oid_code, value|
            oid_code = oid_code[23..-1]
            mappings[oid_code.to_i] = value.downcase
        end

        logger.debug { "found #{mappings.length} ports" }

        @if_mappings = mappings
    ensure
        @processing = nil
    end

    # ifOperStatus: 1.3.6.1.2.1.2.2.1.8.xx == up(1), down(2), testing(3)
    def query_interface_status
        return @processing if @processing
        @processing = :query_interface_status

        logger.debug "querying interface status"

        @client.walk(oid: "1.3.6.1.2.1.2.2.1.8").each do |oid_code, value|
            oid_code = oid_code[20..-1]
            interface = @if_mappings[oid_code.to_i]

            next unless interface

            case value
            when 1 # up
                logger.debug { "Interface Up: #{interface}" }
                remove_reserved(interface)
                @check_interface << interface
            when 2 # down
                logger.debug { "Interface Down: #{interface}" }
                remove_lookup(interface)
            else
                next
            end
        end

        self[:interfaces] = @check_interface.to_a
    ensure
        @processing = nil
    end

    def query_connected_devices
        logger.debug "Querying for connected devices"
        query_interface_status
        query_snooping_bindings
    end

    def update_reservations
        check_reservations
    end


    protected


    def received(data, resolve, command)
        logger.debug { "Switch sent #{data}" }
        data
    end

    def remove_lookup(interface)
        # We are no longer interested in this interface
        @check_interface.delete(interface)

        # Update the status of the switch port
        model = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}")
        if model
            notify = model.disconnected
            details = model.details
            self[interface] = details

            # notify user about reserving their desk
            if notify
                self[:disconnected] = details
                @reserved_interface << interface
            end
        else
            self[interface] = nil
        end
    end

    def remove_reserved(interface)
        return unless @reserved_interface.include? interface
        @reserved_interface.delete interface
        self[:reserved] = @reserved_interface.to_a
    end

    def format(mac)
        mac.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
    end

    def check_reservations
        remove = []

        # Check if the interfaces are still reserved
        @reserved_interface.each do |interface|
            details = ::Aca::Tracking::SwitchPort.find_by_id("swport-#{remote_address}-#{interface}")
            remove << interface unless details.reserved?
            self[interface] = details.details
        end

        # Remove them from the reserved list if not
        if remove.present?
            @reserved_interface -= remove
            self[:reserved] = @reserved_interface.to_a
        end
    end

    def normalise(interface)
        # Port-channel == po
        interface.downcase.gsub('tengigabitethernet', 'te').gsub('gigabitethernet', 'gi').gsub('fastethernet', 'fa')
    end
end
