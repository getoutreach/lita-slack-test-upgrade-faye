require 'faye/websocket'
require 'multi_json'

require_relative 'api'
require_relative 'event_loop'
require_relative 'im_mapping'
require_relative 'message_handler'
require_relative 'room_creator'
require_relative 'user_creator'

module Lita
  module Adapters
    class Slack < Adapter
      # @api private
      class RTMConnection
        MAX_MESSAGE_BYTES = 16_000

        class << self
          def build(robot, config)
            new(robot, config, API.new(config).rtm_connect)
          end
        end

        def initialize(robot, config, team_data)
          @robot = robot
          @config = config
          @websocket_url = team_data.websocket_url
          @robot_id = team_data.self.id
        end

        def run(queue = nil, options = {})
          EventLoop.run do
            log.debug("Connecting to the Slack Real Time Messaging API.")
            @websocket = Faye::WebSocket::Client.new(
              websocket_url,
              nil,
              websocket_options.merge(options)
            )

            websocket.on(:open) { log.debug("Connected to the Slack Real Time Messaging API.") }
            websocket.on(:message) { |event| receive_message(event) }
            websocket.on(:close) do
              log.info("Disconnected from Slack.")
              EventLoop.safe_stop
            end
            websocket.on(:error) { |event| log.debug("WebSocket error: #{event.message}") }

            queue << websocket if queue
          end
        end

        def send_messages(channel, strings)
          strings.each do |string|
            EventLoop.defer { websocket.send(safe_payload_for(channel, string)) }
          end
        end

        def shut_down
          if websocket && EventLoop.running?
            log.debug("Closing connection to the Slack Real Time Messaging API.")
            websocket.close
          end

          EventLoop.safe_stop
        end

        private

        attr_reader :config
        attr_reader :im_mapping
        attr_reader :robot
        attr_reader :robot_id
        attr_reader :websocket
        attr_reader :websocket_url

        def log
          Lita.logger
        end

        def payload_for(channel, string)
          MultiJson.dump({
            id: 1,
            type: 'message',
            text: string,
            channel: channel
          })
        end

        def receive_message(event)
          data = MultiJson.load(event.data)

          EventLoop.defer { MessageHandler.new(robot, robot_id, data).handle }
        end

        def safe_payload_for(channel, string)
          payload = payload_for(channel, string)

          if payload.size > MAX_MESSAGE_BYTES
            raise ArgumentError, "Cannot send payload greater than #{MAX_MESSAGE_BYTES} bytes."
          end

          payload
        end

        def websocket_options
          options = { ping: 10 }
          options[:tls] = { :verify_peer => false }
          # options[:tls] = { :root_cert_file => ['/etc/ssl/certs/ca-certificates.crt'] }
          # options = { ping: 10 , tls: {verify_peer: false}}
          # options = { ping: 10 , tls: {root_cert_file: '/invalid/cert/path'}}
          # options = { ping: 10 , tls: {root_cert_file: '/etc/ssl/certs/ca-certificates.crt'}}
          # options = { ping: 10 , tls: {root_cert_file: '/usr/local/share/ca-certificates/slack-ca.pem'}}
          # options = { ping: 10 , tls: {root_cert_file: '/usr/local/share/ca-certificates/letsencrypt.pem'}}
          # options = { ping: 10 , tls: {root_cert_file: '/etc/ssl/cert.pem'}}
          options[:proxy] = { :origin => config.proxy } if config.proxy
          options
        end

      end
    end
  end
end
