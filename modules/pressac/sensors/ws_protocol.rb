# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'protocols/websocket'
require 'set'

module Pressac; end
module Pressac::Sensors; end

# Data flow:
# ==========
# Pressac desk / environment / other sensor modules wirelessly connect to
# Pressac Smart Gateway (https://www.pressac.com/smart-gateway/) uses AMQP or MQTT protocol to push data to MS Azure IOT Hub via internet
# Local Node-RED docker container (default hostname: node-red) connects to the same Azure IOT hub via AMQP over websocket (using "Azure IoT Hub Receiver" https://flows.nodered.org/node/node-red-contrib-azure-iot-hub)
#   Initial setup: Install the Azure IOT Hub module to the node-red docker container by running:
#    - docker exec -it node-red npm install node-red-contrib-azure-iot-hub
#    - visit http://<engine>:1880 to configure node-red:
#       - create an "Azure IoT Hub Receiver" node. Connect it it to your IOT Hub by setting the connectionstring (see heading "Reading all messages received into Azure IoT Hub": https://flows.nodered.org/node/node-red-contrib-azure-iot-hub)
#       - create a "websocket output" node and connect the output of the Azure node to the input of the websocket node
#       - edit the websocket node and set the Type to be "listen on" and Path to be "/ws/pressac"
# Engine module (instance of this driver) connects to Node-RED via websockets. Typically "ws://node-red:1880/ws/pressac/"

class Pressac::Sensors::WsProtocol
    include ::Orchestrator::Constants

    descriptive_name 'Pressac Sensors via websocket (local Node-RED)'
    generic_name :Websocket
    tcp_port 1880
    wait_response false
    default_settings({
        websocket_path: '/ws/pressac/',
        stale_sensor_threshold: '1h'
    })

    def on_load
        # Environment sensor values (temp, humidity)
        @environment = {}
        self[:environment] = {}

        on_update
    end

    # Called after dependency reload and settings updates
    def on_update
        status = setting(:status) || {}

        @gateways = status[:gateways] || {}
        self[:gateways] = @gateways.dup
        @last_update = status[:last_update] || "Never"
        self[:last_update] = @last_update.dup
	    self[:stale] = []

        @ws_path  = setting('websocket_path')
        @stale_sensor_threshold = UV::Scheduler.parse_duration(setting('stale_sensor_threshold') || '1h') / 1000

        schedule.clear
        schedule.every(setting('stale_sensor_threshold')) { list_stale_sensors }
    end

    def connected
        new_websocket_client
    end

    def disconnected
    end

    def mock(sensor, occupied)
        gateway = which_gateway(sensor)
        @gateways[gateway][sensor] = self[gateway] = {
            id:        'mock_data',
            name:      sensor,
            motion:    occupied,
            voltage:   '3.0',
            location:  nil,
            timestamp: Time.now.to_s,
            gateway:   gateway
        }

        self[:gateways] = @gateways.deep_dup
    end

    def which_gateway(sensor)
        @gateways.each do |g, sensors|
            return g if sensors.include? sensor
        end
    end

    def list_stale_sensors
        now = Time.now.to_i
        @gateways.each do |g, sensors|
            sensors.each do |name, sensor|
                if now - (sensor[:last_update_epoch] || 0 ) > @stale_sensor_threshold
                    @stale << {name => (sensor[:last_update] || "Unknown")}
                end
            end
        end
        self[:stale] = @stale
        # Save the current status to database, so that it can retrieved when engine restarts
        status = {
            last_update: self[:last_update],
            gateways:    @gateways,
            stale:       stale
        }
        define_setting(:status, status)
    end


    protected

    def new_websocket_client
        @ws = Protocols::Websocket.new(self, "ws://#{remote_address + @ws_path}")  # Node that id is optional and only required if there are to be multiple endpoints under the /ws/press/
        @ws.start
    end

    def received(data, resolve, command)
        @ws.parse(data)
        :success
    rescue => e
        logger.print_error(e, 'parsing websocket data')
        disconnect
        :abort
    end

    # ====================
    # Websocket callbacks:
    # ====================

    # websocket ready
    def on_open
        logger.debug { "Websocket connected" }
    end

    def on_message(raw_string)
        logger.debug { "received: #{raw_string}" }
        sensor = JSON.parse(raw_string, symbolize_names: true)

        case (sensor[:deviceType] || sensor[:devicetype])
        when 'Under-Desk-Sensor', 'Occupancy-PIR'
            # Variations in captialisation of sensor's key names exist amongst different firmware versions
            sensor_name = sensor[:deviceName].to_sym  || sensor[:devicename].to_sym
            gateway     = sensor[:gatewayName].to_sym || 'unknown_gateway'.to_sym
            occupancy   = sensor[:motionDetected] == true

            # store the new sensor data under the gateway name (self[:gateways][gateway][sensor_name]),
            # AND as the latest notification from this gateway (self[gateway]) (for the purpose of the DeskManagent logic upstream)
            @gateways[gateway] ||= {}
            @gateways[gateway][sensor_name] = {
                id:        sensor[:deviceId] || sensor[:deviceid],
                name:      sensor_name,
                motion:    occupancy,
                voltage:   sensor[:supplyVoltage][:value] || sensor[:supplyVoltage],
                location:  sensor[:location],
                timestamp: sensor[:timestamp],
                last_update: Time.now.in_time_zone($TZ).to_s,
                last_update_epoch: Time.now.to_i,
                gateway:   gateway
            }
            self[gateway]   = @gateways[gateway][sensor_name].dup
            self[:gateways] = @gateways.deep_dup
            if @stale[sensor_name]
                @stale.except!(sensor_name)
                self[:stale] = @stale.deep_dup
            end
        when 'CO2-Temperature-and-Humidity'
            @environment[sensor[:devicename]] = {
                temp:           sensor[:temperature],
                humidity:       sensor[:humidity],
                concentration:  sensor[:concentration],
                dbm:            sensor[:dbm],
                id:             sensor[:deviceid]
            }
            self[:environment] = @environment.deep_dup
        end

        self[:last_update] = Time.now.in_time_zone($TZ).to_s

        # Save the current status to database, so that it can retrieved when engine restarts
        status = {
            last_update: self[:last_update],
            gateways:    @gateways.deep_dup,
            stale:       self[:stale]
        }
        define_setting(:status, status)
    end

    # connection is closing
    def on_close(event)
        logger.debug { "Websocket closing... #{event.code} #{event.reason}" }
    end

    def on_error(error)
        logger.warn "Websocket error: #{error.message}"
    end
end
