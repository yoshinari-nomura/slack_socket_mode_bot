# frozen_string_literal: true

require "uri"
require "net/http"
require "openssl"
require "websocket"
require "json"

require_relative "slack_socket_mode_bot/version"
require_relative "slack_socket_mode_bot/simple_web_socket"

class SlackSocketModeBot
  class Error < StandardError; end

  attr_reader :name, :user_id, :cannonical_name

  #: (token: String, ?app_token: String, ?num_of_connections: Integer, ?debug: boolean, ?logger: Logger) { (untyped) -> untyped } -> void
  def initialize(name:, token:, app_token: nil, num_of_connections: 4, debug: false, logger: nil, &callback)
    @name = name
    @token = token
    @app_token = app_token
    @conns = []
    @debug = debug
    @logger = logger
    @events = {}
    auth_info = web_client.auth_test
    @user_id = auth_info.user_id
    @cannonical_name = auth_info.user
    num_of_connections.times { add_connection(callback) } if app_token
  end

  def web_client
    self
  end

  def chat_postMessage(options = {})
    call("chat.postMessage", options)
  end
  alias_method :say, :chat_postMessage

  def users_info(options = {})
    to_open_struct(call("users.info", options, http_method: :get))
  end

  def conversations_replies(options = {})
    to_open_struct(call("conversations.replies", options, http_method: :get))
  end

  def name?(bot_name)
    bot_name == name
  end

  # https://api.slack.com/methods/auth.test
  # auth_info = web_client.auth_test
  #
  # puts "name: #{auth_info.user} id: #{auth_info.user_id}"
  #
  def auth_test(options = {})
    to_open_struct(call("auth.test", options, http_method: :post))
  end

  #: (String method, untyped data, ?token: String) -> untyped
  def call(method, data, token: @token, http_method: :post)
    count = 0
    begin
      url = URI("https://slack.com/api/" + method)

      if http_method == :get
        url.query = URI.encode_www_form(data)

        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = (url.scheme == "https")
        request = Net::HTTP::Get.new(url)
        request["Authorization"] = "Bearer " + token

        res = http.request(request)
        puts "----------------------------------------------"
        pp JSON.parse(res.body, symbolize_names: true)
      else
        res = Net::HTTP.post(
          url, JSON.generate(data),
          "Content-type" => "application/json; charset=utf-8",
          "Authorization" => "Bearer " + token,
        )
      end
      json = JSON.parse(res.body, symbolize_names: true)
      raise Error, json[:error] unless json[:ok]
      json
    # rescue Socket::ResolutionError
    rescue SocketError
      sleep 1
      count += 1
      retry if count < 3
      raise
    end
  end

  private def to_open_struct(obj)
    case obj
    when Hash
      OpenStruct.new(
        obj.transform_values do |v|
        to_open_struct(v)
      end
      )
    when Array
      obj.map do |v|
        to_open_struct(v)
      end
    else
      obj
    end
  end

  private def add_connection(callback)
    json = call("apps.connections.open", {}, token: @app_token)

    url = json[:url]
    url += "&debug_reconnects=true" if @debug
    ws = SimpleWebSocket.new(url) do |type, data|
      case type
      when :open
        @logger.info("[ws:#{ ws.object_id }] websocket open") if @logger
      when :close
        @logger.info("[ws:#{ ws.object_id }] websocket closed") if @logger
        add_connection(callback)
      when :message
        begin
          json = JSON.parse(data, symbolize_names: true)
        rescue JSON::ParserError
          add_connection(callback)
          next
        end

        if @logger
          @logger.debug("[ws:#{ ws.object_id }] slack message: #{ JSON.generate(json) }")
        end

        case json[:type]
        when "hello"
          @logger.info("[ws:#{ ws.object_id }] hello (active connections: #{ @conns.size })") if @logger
        when "disconnect"
          ws.close
          @logger.info("[ws:#{ ws.object_id }] disconnect (active connections: #{ @conns.size })") if @logger
        else
          payload = json[:payload]
          if @logger
            msg = "[ws:#{ ws.object_id }] #{ json[:type] } [##{ json[:retry_attempt] + 1 }] (#{
              {
                event_id: payload[:event_id],
                event_time: Time.at(payload[:event_time]).strftime("%FT%T"),
                type: payload[:type],
              }.map {|k, v| "#{ k }: #{ v }" }.join(", ")
            })"
            @logger.info(msg)
          end
          expired = Time.now.to_i - 600
          @events.reject! {|_, timestamp| timestamp < expired }

          if @events[json[:payload][:event_id]]
            # ignore
          else
            @events[json[:payload][:event_id]] = json[:payload][:event_time]

            response = { envelope_id: json[:envelope_id] }
            if json[:accepts_response_payload]
              response[:payload] = callback.call(json)
            else
              callback.call(json)
            end
            ws.send(JSON.generate(response))
          end
        end
      end
    end

    @conns << ws
  end

  #: -> [Array[IO], Array[IO]]
  def step
    read_ios, write_ios = [], []
    @conns.select! {|ws| ws.step(read_ios, write_ios) }
    return read_ios, write_ios
  end

  #: -> bot
  def run
    while true
      read_ios, write_ios = step
      IO.select(read_ios, write_ios)
    end
  end
end
