# frozen_string_literal: true

load File.join(__dir__, 'room_os.rb')
load File.join(__dir__, 'ui_extensions.rb')
load File.join(__dir__, 'external_source.rb')

class Cisco::CollaborationEndpoint::Sx80 < Cisco::CollaborationEndpoint::RoomOs
    include ::Cisco::CollaborationEndpoint::Xapi::Mapper
    include ::Cisco::CollaborationEndpoint::UiExtensions
    include ::Cisco::CollaborationEndpoint::ExternalSource

    descriptive_name 'Cisco SX80'
    description <<~DESC
        Control of Cisco SX80 devices.

        API access requires a local user with the 'integrator' role to be
        created on the codec.
    DESC

    tokenize delimiter: Tokens::COMMAND_RESPONSE,
             wait_ready: Tokens::LOGIN_COMPLETE
    clear_queue_on_disconnect!

    def connected
        super

        register_feedback '/Event/PresentationPreviewStarted' do
            self[:local_presentation] = true
        end
        register_feedback '/Event/PresentationPreviewStopped' do
            self[:local_presentation] = false
        end
    end

    status 'Audio Microphones Mute' => :mic_mute
    status 'Audio Volume' => :volume
    status 'Cameras PresenterTrack' => :presenter_track
    status 'Cameras SpeakerTrack' => :speaker_track
    status 'RoomAnalytics PeoplePresence' => :presence_detected
    status 'Conference DoNotDisturb' => :do_not_disturb
    status 'Conference Presentation Mode' => :presentation
    status 'Peripherals ConnectedDevice' => :peripherals
    status 'SystemUnit State NumberOfActiveCalls' => :active_calls
    status 'Video SelfView Mode' => :selfview
    status 'Video Input' => :video_input
    status 'Video Output' => :video_output
    status 'Standby State' => :standby

    command 'Audio Microphones Mute' => :mic_mute_on
    command 'Audio Microphones Unmute' => :mic_mute_off
    command 'Audio Microphones ToggleMute' => :mic_mute_toggle
    def mic_mute(state = On)
        is_affirmative? state ? mic_mute_on : mic_mute_off
    end

    command 'Audio Sound Play' => :play_sound,
            Sound: [:Alert, :Bump, :Busy, :CallDisconnect, :CallInitiate,
                    :CallWaiting, :Dial, :KeyInput, :KeyInputDelete, :KeyTone,
                    :Nav, :NavBack, :Notification, :OK, :PresentationConnect,
                    :Ringing, :SignIn, :SpecialInfo, :TelephoneCall,
                    :VideoCall, :VolumeAdjust, :WakeUp],
            Loop_: [:Off, :On]
    command 'Audio Sound Stop' => :stop_sound

    command 'Audio Volume Set' => :volume,
            Level: (0..100)

    command 'Call Disconnect' => :hangup, CallId_: Integer
    command 'Dial' => :dial,
            Number:  String,
            Protocol_: [:H320, :H323, :Sip, :Spark],
            CallRate_: (64..6000),
            CallType_: [:Audio, :Video]

    command 'Camera PositionReset' => :camera_position_reset,
            CameraId: (1..7),
            Axis_: [:All, :Focus, :PanTilt, :Zoom]
    command 'Camera Ramp' => :camera_move,
            CameraId: (1..7),
            Pan_: [:Left, :Right, :Stop],
            PanSpeed_: (1..15),
            Tilt_: [:Down, :Up, :Stop],
            TiltSpeed_: (1..15),
            Zoom_: [:In, :Out, :Stop],
            ZoomSpeed_: (1..15),
            Focus_: [:Far, :Near, :Stop]

    command! 'Cameras AutoFocus Diagnostics Start' => \
             :autofocus_diagnostics_start,
             CameraId: (1..7)
    command! 'Cameras AutoFocus Diagnostics Stop' => \
             :autofocus_diagnostics_stop,
             CameraId: (1..7)

    command! 'Cameras PresenterTrack ClearPosition' => :presenter_track_clear
    command! 'Cameras PresenterTrack StorePosition' => :presenter_track_store
    command! 'Cameras PresenterTrack Set' => :presenter_track,
             Mode: [:Off, :Follow, :Diagnostic, :Background, :Setup,
                    :Persistant]

    command! 'Cameras SpeakerTrack Diagnostics Start' => \
             :speaker_track_diagnostics_start
    command! 'Cameras SpeakerTrack Diagnostics Stop' => \
             :speaker_track_diagnostics_stop

    # The 'integrator' account can't active/deactive SpeakerTrack, but we can
    # cut off access via a configuration setting.
    def speaker_track(state = On)
        mode = is_affirmative?(state) ? :Auto : :Off
        send_xconfiguration 'Cameras SpeakerTrack', :Mode, mode
    end

    command 'Conference DoNotDisturb Activate' => :do_not_disturb_activate,
            Timeout_: (1..1440)
    command 'Conference DoNotDisturb Deactivate' => :do_not_disturb_deactivate

    command 'Standby Deactivate' => :powerup
    command 'Standby HalfWake' => :half_wake
    command 'Standby Activate' => :standby
    command 'Standby ResetTimer' => :reset_standby_timer, Delay: (1..480)
    def power(state = false)
        if is_affirmative? state
            powerup
        elsif is_negatory? state
            standby
        elsif state.to_s =~ /wake/i
            half_wake
        else
            logger.error "Invalid power state: #{state}"
        end
    end

    command! 'SystemUnit Boot' => :reboot, Action_: [:Restart, :Shutdown]
end