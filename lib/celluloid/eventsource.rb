require "celluloid/eventsource/version"
require 'celluloid/io'
require 'celluloid/eventsource/response_parser'
require 'uri'

module Celluloid
  class EventSource
    include  Celluloid::IO

    attr_reader :url, :with_credentials
    attr_reader :ready_state

    CONNECTING = 0
    OPEN = 1
    CLOSED = 2

    def initialize(uri, options = {})
      options  = options.dup
      self.url = uri
      @ready_state = CONNECTING
      @with_credentials = options.delete(:with_credentials) { false }

      @reconnect_timeout = 10
      @last_event_id = String.new
      @on = { open: ->{}, message: ->(_) {}, error: ->(_) {} }
      @parser = ResponseParser.new

      yield self if block_given?

      async.listen
    end

    def url=(uri)
      @url = URI(uri)
    end

    def connected?
      ready_state == OPEN
    end

    def closed?
      ready_state == CLOSED
    end

    def listen!
      async.listen
    end

    def listen
      establish_connection

      until closed? || @socket.eof?
        @parser << @socket.readline

        process_stream(@parser.chunk)
      end
    rescue IOError
      # Closing the socket during read causes this exception and kills the actor
      # We really don't wan to do anything if the socket is closed.
    end

    def establish_connection
      @socket = Celluloid::IO::TCPSocket.new(@url.host, @url.port)

      @socket.write(request_string)

      until @parser.headers?
        @parser << @socket.readline
      end

      if @parser.status_code != 200
        close
        @on[:error].call("Unable to establish connection. Response status #{@parser.status_code}")
      end

      handle_headers(@parser.headers)
    end

    def close
      @socket.close if @socket
      @ready_state = CLOSED
    end

    def on(event_name, &action)
      @on[event_name.to_sym] = action
    end

    def on_open(&action)
      @on[:open] = action
    end

    def on_message(&action)
      @on[:message] = action
    end

    def on_error(&action)
      @on[:error] = action
    end

    private

    def process_stream(stream)
      data = ""
      event_name = :message

      stream.split("\n").each do |part|
        case part
          when /^data:(.+)$/
            data = $1
          when /^id:(.+)$/
            @last_event_id = $1
          when /^retry:(.+)$/
            @reconnect_timeout = $1.to_i
          when /^event:(.+)$/
            event_name = $1.strip.to_sym
        end
      end

      return if data.empty?
      data.chomp!("\n")

      @on[event_name] && @on[event_name].call(data)
    end

    def handle_headers(headers)
      if headers['Content-Type'].include?("text/event-stream")
        @ready_state = OPEN
        @on[:open].call
      else
        close
        @on[:error].call("Invalid Content-Type #{headers['Content-Type']}. Expected text/event-stream")
      end
    end

    def request_string
      "GET #{url.request_uri} HTTP/1.1\r\nHost: #{url.host}\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\n\r\n"
    end

  end

end
