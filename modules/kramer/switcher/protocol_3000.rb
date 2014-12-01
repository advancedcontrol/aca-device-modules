module Kramer; end
module Kramer::Switcher; end


# :title:Kramer video switches
#
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# video_inputs
# video_outputs
#
# video1 => input
# video2
# video3
#

#
# NOTE:: These devices should be marked as make and break!
#

class Kramer::Switcher::Protocol3000
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
	
	def on_load
		config({
            tokenize: true,
            delimiter: "\x0D\x0A",
            indicator: '~',
            encoding: "ASCII-8BIT"
        })

        on_update
	end

	def on_update
		@device_id = setting(:kramer_id)
		@destination = "#{@device_id}@" if @device_id

		@login_level = setting(:kramer_login)
		@password = setting(:kramer_password) if @login_level
    end
	
	def connected
		#
		# Get current state of the switcher
		#
		protocol_handshake
		login
		get_machine_info

		@polling_timer = schedule.every('2m') do
			logger.debug "-- Kramer Maintaining Connection"
			do_send('MODEL?', {:priority => 0})	# Low priority poll to maintain connection
		end
	end

	def disconnected
		@polling_timer.cancel unless @polling_timer.nil?
		@polling_timer = nil
	end
	
	
	#
	# Starting at input 1, input 0 == disconnect
	#
	def switch(map, out = nil)
		map = {map => out} if out
		do_send(CMD[:switch], build_switch_data(map))
	end


	def switch_video(map, out = nil)
		map = {map => out} if out
		do_send(CMD[:switch_video], build_switch_data(map))
	end


	def switch_audio(map, out = nil)
		map = {map => out} if out
		do_send(CMD[:switch_audio], build_switch_data(map))
	end


	def mute_video(state = true)
		data = is_affirmative?(state) ? 1 : 0
		do_send(cmd[:video_mute], data)
	end

	def mute_audio(state = true)
		data = is_affirmative?(state) ? 1 : 0
		do_send(cmd[:audio_mute], data)
	end

	def unmute_video
		mute_video false
	end

	def unmute_audio
		mute_audio false
	end
	

	def received(data, resolve, command)
		logger.debug "Kramer sent #{data}"
		
		# Extract and check the machine number if we've defined it
		components = data.split('@')
		if components.length > 1
			machine = components[0]
			if @device_id && machine != @device_id
				return :ignore
			end
		end

		data = components[-1].strip
		components = data.split(' ')

		cmd = data[0].to_sym
		args = data[1..-1]

		if cmd == :OK
			return :success
		elsif cmd == :ERR || args[0] == 'ERR'
			error = cmd == :ERR ? args[0] : args[1]
			logger.error "Kramer command error #{error}"
			self[:last_error] = error
			return :abort
		end

		case CMDS[cmd]
		when :info
			self[:video_inputs] = args[1].to_i
			self[:video_outputs] = args[3].to_i
		when :route
			inout = args[0].split(',')
			layer = inout[0].to_i
			dest = inout[1].to_i
			src = inout[2].to_i
			self[:"#{LAYERS[layer]}#{dest}"] = src
		when :switch, :switch_audio, :switch_video
			# return string like "in>out,in>out,in>out"

			type = :av
			type = :audio if CMDS[cmd] == :switch_audio
			type = :video if CMDS[cmd] == :switch_video

			mappings = args[0].split(',')
			mapping.each do |map|
				inout = map.split('>')
				self[:"#{type}#{inout[1]}"] = inout[0].to_i
			end
		when :audio_mute
			output, mute = args[0].split(',')
			self[:"audio#{output}_muted"] = mute == '1'
		when :video_mute
			output, mute = args[0].split(',')
			self[:"video#{output}_muted"] = mute == '1'
		end
		
		return :success
	end


	CMDS = {
		info: :"INFO-IO?",
		login: :"LOGIN",
		route: :"ROUTE",
		switch: :"AV",
		switch_audio: :"AUD",
		switch_video: :"VID",
		audio_mute: :"MUTE",
		video_mute: :"VMUTE"
	}
	CMDS.merge!(CMDS.invert)

	LAYERS = {
		1 => :video,
		2 => :audio,
		2 => :data
	}
	
	
	private


	def build_switch_data(map)
		data = ''

		map.each do |input, outputs|
			outputs = [outputs] unless outputs.class == Array
			input = input.to_s if input.class == Symbol
			input = input.to_i if input.class == String
			outputs.each do |output|
				data << "#{input}>#{output},"
			end
		end

		data.chop
	end


	def protocol_handshake
		do_send('', {priority: 99})
	end

	def login
		if @login_level
			do_send(CMDS[:login], @password, {priority: 99})
		end
	end

	def get_machine_info
		do_send(CMDS[:info], {priority: 99})
	end


	def do_send(command, *args)
		options = {}
		if args[-1].is_a? Hash
			options = args.pop
		end

		cmd = "##{@destination}#{command}"

		if args.length > 0
			cmd << " #{args.join(',')}"
		end
		cmd << "\r"

		send(cmd, options)
	end
end
