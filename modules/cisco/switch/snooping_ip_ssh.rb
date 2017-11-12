module Cisco; end
module Cisco::Switch; end

require 'set'
::Orchestrator::DependencyManager.load('Aca::Tracking::MacLocation', :model, :force)
::Aca::Tracking::MacLocation.ensure_design_document!

class Cisco::Switch::SnoopingIpSsh
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    descriptive_name 'Cisco Switch IP Snooping over SSH'
    generic_name :Snooping

    # Discovery Information
    tcp_port 22
    implements :ssh

    # Communication settings
    tokenize delimiter: /\n|<space>/,
             wait_ready: ':'
    clear_queue_on_disconnect!

    default_settings username: :cisco, password: :cisco


    def on_load
        @check_interface = ::Set.new

        query = ::Aca::Tracking::MacLocation.find_by_switch_ip(remote_address)
        query.stream do |detail|
            self[detail.interface] = [detail.device_ip, detail.mac_address]
            self[detail.device_ip] = ::Aca::Tracking::MacLocation.bucket.get("ipmac-#{detail.device_ip}", quiet: true)
        end

        on_update
    end

    def on_update
        @switch_name = setting(:switch_name)
    end

    def connected
        @username = setting(:username) || 'cisco'
        do_send(@username, priority: 99)

        schedule.every('1m') { query_connected_devices }
    end

    def disconnected
        schedule.clear
    end

    # Don't want the every day user using this method
    protect_method :run
    def run(command, options = {})
        do_send command, **options
    end

    def query_snooping_bindings
        do_send 'show ip dhcp snooping binding'
    end

    def query_interface_status
        do_send 'show interfaces status'
    end

    def query_connected_devices
        logger.debug { "Querying for connected devices" }
        query_interface_status
        schedule.in(3000) { query_snooping_bindings }
    end


    protected


    def received(data, resolve, command)
        logger.debug { "Switch sent #{data}" }

        # Authentication occurs after the connection is established
        if data =~ /#{@username}/
            logger.debug { "Authenticating" }
            # Don't want to log the password ;)
            send("#{setting(:password)}\n", priority: 99)
            schedule.in(2000) { query_connected_devices }
            return :success
        end

        # determine the hostname
        if @hostname.nil?
            parts = data.split('#')
            if parts.length == 2
                self[:hostname] = @hostname = parts[0]
                return :success # Exit early as this line is not a response
            end
        end

        # Detect more data available
        # ==> More: <space>,  Quit: q or CTRL+Z, One line: <return>
        if data =~ /More:/
            send(' ', priority: 99)
            return :success
        end

        # Interface change detection
        # 07-Aug-2014 17:28:26 %LINK-I-Up:  gi2
        # 07-Aug-2014 17:28:31 %STP-W-PORTSTATUS: gi2: STP status Forwarding
        # 07-Aug-2014 17:44:43 %LINK-I-Up:  gi2, aggregated (1)
        # 07-Aug-2014 17:44:47 %STP-W-PORTSTATUS: gi2: STP status Forwarding, aggregated (1)
        # 07-Aug-2014 17:45:24 %LINK-W-Down:  gi2, aggregated (2)
        if data =~ /%LINK/
            interface = data.split(',')[0].split(/\s/)[-1].downcase

            if data =~ /Up:/
                logger.debug { "Interface Up: #{interface}" }
                @check_interface << interface
                schedule.in(3000) { query_snooping_bindings }
            elsif data =~ /Down:/
                logger.debug { "Interface Down: #{interface}" }
                remove_lookup(interface)
            end

            self[:interfaces] = @check_interface.to_a

            return :success
        end

        # Grab the parts of the response
        entries = data.split(/\s+/)

        # show interfaces status
        # gi1      1G-Copper    Full    1000  Enabled  Off  Up          Disabled On
        # gi2      1G-Copper      --      --     --     --  Down           --     --
        # OR
        # Port    Name               Status       Vlan       Duplex  Speed Type
        # Gi1/1                      notconnect   1            auto   auto No Gbic
        # Fa6/1                      connected    1          a-full  a-100 10/100BaseTX
        if entries.include?('Up') || entries.include?('connected')
            interface = entries[0].downcase
            logger.debug { "Interface Up: #{interface}" }
            @check_interface << interface.downcase
            self[:interfaces] = @check_interface.to_a
            return :success

        elsif entries.include?('Down') || entries.include?('notconnect')
            interface = entries[0].downcase
            logger.debug { "Interface Down: #{interface}" }
            
            # Delete the lookup records
            remove_lookup(interface)
            self[:interfaces] = @check_interface.to_a
            return :success
        end

        # We are looking for MAC to IP address mappings
        # =============================================
        # Total number of binding: 1
        #
        #    MAC Address       IP Address    Lease (sec)     Type    VLAN Interface
        # ------------------ --------------- ------------ ---------- ---- ----------
        # 38:c9:86:17:a2:07  192.168.1.15    166764       learned    1    gi3
        if @check_interface.present? && !entries.empty?
            interface = entries[-1].downcase

            # We only want entries that are currently active
            if @check_interface.include? interface

                # Ensure the data is valid
                mac = entries[0]
                if mac =~ /^(?:[[:xdigit:]]{1,2}([-:]))(?:[[:xdigit:]]{1,2}\1){4}[[:xdigit:]]{1,2}$/
                    mac.downcase!
                    ip = entries[1]

                    if ::IPAddress.valid? ip
                        if self[ip] != mac
                            logger.debug { "Recording lookup for #{ip} => #{mac}" }
                            self[ip] = mac
                            ::Aca::Tracking::MacLocation.bucket.set("ipmac-#{ip}", mac, expire_in: 1.week)
                        end

                        if self[interface] != [ip, mac]
                            lookup = ::Aca::Tracking::MacLocation.find_by_id("macloc-#{mac}")
                            if lookup
                                # detect IP address change
                                logger.debug { "Updating location of #{mac}" }
                                remove_ip_to_mac_lookup(lookup.device_ip, mac) if lookup.device_ip != ip
                            else
                                logger.debug { "Recording location of #{mac}" }
                                lookup = ::Aca::Tracking::MacLocation.new
                            end
                            lookup.mac_address = mac
                            lookup.device_ip   = ip
                            lookup.switch_ip   = remote_address
                            lookup.hostname    = @hostname
                            lookup.switch_name = @switch_name
                            lookup.interface   = interface
                            lookup.save!(expire_in: 1.week)
                            self[interface] = [ip, mac]
                        end
                    end
                end

            end
        end

        :success
    end

    def do_send(cmd, **options)
        logger.debug { "requesting #{cmd}" }
        send("#{cmd}\n", options)
    end

    def remove_lookup(interface)
        ip, mac = self[interface]
        return unless mac

        @check_interface.delete(interface)

        # Delete the IP to MAC lookup
        remove_ip_to_mac_lookup(ip, mac)

        # Make sure this MAC address hasn't been found somewhere else
        model = ::Aca::Tracking::MacLocation.find_by_id("macloc-#{mac}")
        if model && model.switch_ip == remote_address && model.interface == interface
            # CAS == Compare and Swap
            # don't delete if the record has been updated
            model.destroy(with_cas: true)
            logger.debug { "Removing location of #{mac}" }
        end
        self[interface] = nil
    end

    def remove_ip_to_mac_lookup(ip, mac)
        logger.debug { "Removing lookup for #{ip} => #{mac}" }

        bucket = ::Aca::Tracking::MacLocation.bucket
        key = "ipmac-#{ip}"
        resp = bucket.get(key, quiet: true, extended: true)
        if resp&.value == mac
            begin
                bucket.delete(key, cas: resp.cas)
            rescue Libcouchbase::Error::KeyExists
                # CAS failed we can safely ignore this
            end
        end
    end
end
