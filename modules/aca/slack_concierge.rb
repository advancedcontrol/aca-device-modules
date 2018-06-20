require 'slack-ruby-client'
require 'slack/real_time/concurrency/libuv'

class Aca::SlackConcierge
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security


    descriptive_name 'Slack Concierge Connector'
    generic_name :Slack
    implements :logic

    def log(msg)
        logger.info msg
        STDERR.puts msg
        STDERR.flush
    end

    def on_load
        on_update
    end

    def on_update
        on_unload   
        create_websocket
        self[:building] = setting(:building) || :barangaroo
        self[:channel] = setting(:channel) || :concierge
    end

    def on_unload
        @client.stop! if @client && @client.started?
        @client = nil
    end

    # Message from the concierge frontend
    def send_message(message_text, thread_id)
        message = @client.web_client.chat_postMessage channel: setting(:channel), text: message_text, thread_ts: thread_id, username: 'Concierge'
    end

    def update_last_message_read(email)
        authority_id = Authority.find_by_domain('uat-book.internationaltowers.com').id
        user = User.find_by_email(authority_id, email)
        user.last_message_read = Time.now.to_i * 1000
        user.save!
    end

    def get_threads
        messages = @client.web_client.channels_history({channel: setting(:channel), oldest: (Time.now - 12.months).to_i, count: 1000})['messages']
        messages.delete_if{ |message|
            !((!message.key?('thread_ts') || message['thread_ts'] == message['ts']) && message['subtype'] == 'bot_message')
        }
        logger.debug "Processing messages in get_threads"
        messages.each_with_index{|message, i|            
            if message['username'].include?('(')
                messages[i]['name'] = message['username'].split(' (')[0] if message.key?('username')
                messages[i]['email'] = message['username'].split(' (')[1][0..-2] if message.key?('username')
                authority_id = Authority.find_by_domain('uat-book.internationaltowers.com').id
                log("GOT AUTHORITY ID")
                log(authority_id)
                log("GOT EMAIL")
                log(messages[i]['email'])
                user = User.find_by_email(authority_id, messages[i]['email'])
                if !user.nil?
                    messages[i]['last_sent'] = user.last_message_sent
                    messages[i]['last_read'] = user.last_message_read
                else
                    messages[i]['last_sent'] = nil
                    messages[i]['last_read'] = nil
                end
                # update_last_message_read(messages[i]['email'])
            else
                messages[i]['name'] = message['username']
            end
            messages[i]['replies'] = get_message(message['ts'])
        }
        logger.debug "Finished processing messages in get_threads"
        logger.debug messages[0]
        self["threads"] = messages
    end

    def get_message(ts)
        messages = @client.web_client.channels_history({channel: setting(:channel), latest: ts, inclusive: true})['messages'][0]
    end

    def get_thread(thread_id)
        # Get the messages
        slack_api = UV::HttpEndpoint.new("https://slack.com")
        req = {
            token: @client.token,
            channel: setting(:channel),
            thread_ts: thread_id
        }
        response = slack_api.post(path: 'https://slack.com/api/channels.replies', body: req).value
        messages = JSON.parse(response.body)['messages']
        self["thread_#{thread_id}"] = messages
        return nil
    end

    def update_read_time(thread_id)
        user = User.find(User.bucket.get("slack-user-#{thread_id}", quiet: true))
        user.last_message_read = Time.now.to_i * 1000
        user.save!
    end

    protected

    # Create a realtime WS connection to the Slack servers
    def create_websocket

        logger.debug "Creating websocket"

        ::Slack.configure do |config|
            config.token = setting(:slack_api_token)
            # config.logger = logger
            config.logger = Logger.new(STDOUT)
            config.logger.level = Logger::INFO
            fail 'Missing slack api token setting!' unless config.token
        end

        logger.debug "Configured slack"

        ::Slack::RealTime.configure do |config|
            config.concurrency = Slack::RealTime::Concurrency::Libuv
        end
        logger.debug "Configured slack concurrency"
        

        @client = ::Slack::RealTime::Client.new
        
        get_threads

        logger.debug "Created client!!"

        @client.on :message do |data|
            logger.debug "----------------- Got message! -----------------"
            logger.debug data
            logger.debug "------------------------------------------------"

            begin
                #@client.typing channel: data.channel
                # Disregard if we have a subtype key and it's a reply to a message
                if data.key?('subtype') && data['subtype'] == 'message_replied'
                    next
                end
                user_email = nil
                # # This is not a reply 
                if data.key?('thread_ts')
                    #  if data['username'].include?('(')
                    #     user_email = data['username'].split(' (')[1][0..-2] if data.key?('username')
                    # end
                    get_thread(data['ts'])
                    get_thread(data['thread_ts'])
                else
                    logger.info "Adding thread to binding"
                    if data['username'].include?('(')
                        data['name'] = data['username'].split(' (')[0] if data.key?('username')
                        data['email'] = data['username'].split(' (')[1][0..-2] if data.key?('username')
                        # user_email = data['email']
                    else
                        data['name'] = data['username']
                    end
                    messages = self["threads"].dup.unshift(data)
                    self["threads"] = messages
                    # if user_email
                    #     authority_id = Authority.find_by_domain('uat-book.internationaltowers.com').id
                    #     user = User.find_by_email(authority_id, user_email)
                    #     user.last_message_read = Time.now.to_i * 1000
                    #     user.save!
                    # end
                    logger.debug "Getting threads! "
                    get_threads
                end

                
                
            rescue Exception => e
                logger.debug e.message
                logger.debug e.backtrace
            end
        end

        @client.start!

    end
end
