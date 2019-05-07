
Orchestrator::Testing.mock_device 'Cisco::Switch::SnoopingCatalystSNMP' do
    trapper = ::Aca::SnmpManager.new
    trapper.register(thread, manager.logger, '127.0.0.1') do |pdu, ip, port|
        exec(:check_link_state, pdu)
    end

    # Force some ifMappings into the driver
    manager.instance.instance_exec do
        @if_mappings = {
            26 => 'gi1/0/19',
            35 => 'gi1/0/28',
            48 => 'te1/0/41'
        }
    end

    example_up = "0\x81\x8B\x02\x01\x00\x04\v5rNTg!pm1ck\xA4y\x06\b+\x06\x01\x06\x03\x01\x01\x05@\x04\n\xE6\xFE\x1C\x02\x01\x03\x02\x01\x00C\x04\x0E\xA2\xC8H0[0\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x01\x1A\x02\x01\x1A0#\x06\n+\x06\x01\x02\x01\x02\x02\x01\x02\x1A\x04\x15GigabitEthernet1/0/190\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x03\x1A\x02\x01\x060\x12\x06\f+\x06\x01\x04\x01\t\x02\x02\x01\x01\x14\x1A\x04\x02up"
    trapper.new_message(example_up, '127.0.0.1', 161)

    example_down = "0\x81\x90\x02\x01\x00\x04\v5rNTg!pm1ck\xA4~\x06\b+\x06\x01\x06\x03\x01\x01\x05@\x04\n\xE6\xFE/\x02\x01\x02\x02\x01\x00C\x04\t\xD1E\x020`0\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x010\x02\x0100&\x06\n+\x06\x01\x02\x01\x02\x02\x01\x020\x04\x18TenGigabitEthernet1/0/410\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x030\x02\x01\x060\x14\x06\f+\x06\x01\x04\x01\t\x02\x02\x01\x01\x140\x04\x04down"
    trapper.new_message(example_down, '127.0.0.1', 161)

    example_up = "0\x81\x8B\x02\x01\x00\x04\v5rNTg!pm1ck\xA4y\x06\b+\x06\x01\x06\x03\x01\x01\x05@\x04\n\xE6\xFE\x13\x02\x01\x03\x02\x01\x00C\x04\x0E\xA3\xE5S0[0\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x01#\x02\x01#0#\x06\n+\x06\x01\x02\x01\x02\x02\x01\x02#\x04\x15GigabitEthernet1/0/280\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x03#\x02\x01\x060\x12\x06\f+\x06\x01\x04\x01\t\x02\x02\x01\x01\x14#\x04\x02up"
    trapper.new_message(example_up, '127.0.0.1', 161)

    expect(status[:interfaces]).to eq(['gi1/0/19', 'gi1/0/28'])

    example_down = "0\x81\x8D\x02\x01\x00\x04\v5rNTg!pm1ck\xA4{\x06\b+\x06\x01\x06\x03\x01\x01\x05@\x04\n\xE6\xFE\x13\x02\x01\x02\x02\x01\x00C\x04\x0E\xA3\xE7{0]0\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x01#\x02\x01#0#\x06\n+\x06\x01\x02\x01\x02\x02\x01\x02#\x04\x15GigabitEthernet1/0/280\x0F\x06\n+\x06\x01\x02\x01\x02\x02\x01\x03#\x02\x01\x060\x14\x06\f+\x06\x01\x04\x01\t\x02\x02\x01\x01\x14#\x04\x04down"
    trapper.new_message(example_down, '127.0.0.1', 161)

    expect(status[:interfaces]).to eq(['gi1/0/19'])
end
