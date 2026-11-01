# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "time"
require "uri"
require_relative "operations"

module Hermetica
  # Raised for any non-2xx answer. `message` is "status code: error_message".
  class Error < StandardError
    attr_reader :status, :code, :error_message, :details

    def initialize(status, code, error_message, details = nil)
      super("#{status} #{code}: #{error_message}")
      @status = status
      @code = code
      @error_message = error_message
      @details = details
    end
  end

  # Standard library only. `Hermetica::Client.new("hm_sk_...", base_url: "https://api.example.com")`.
  class Client
    include Operations

    # Network errors and timeouts (Net::OpenTimeout and Net::ReadTimeout are Timeout::Errors).
    NETWORK_ERRORS = [IOError, SystemCallError, SocketError, Timeout::Error].freeze

    attr_reader :api_key, :base_url, :workspace_id, :timeout, :max_retries

    # `max_retries:` is how many times a network error, 429 or 5xx is retried after the first attempt; 0 turns retries off.
    def initialize(api_key, base_url: "http://localhost:4000", workspace_id: nil, timeout: 30, max_retries: 3)
      @api_key = api_key
      @base_url = base_url.sub(%r{/+\z}, "")
      @workspace_id = workspace_id
      @timeout = timeout
      @max_retries = max_retries
    end

    def request(method, path, path_params: nil, query: nil, body: nil, idempotency_key: nil)
      params = path_params || {}
      path = path.gsub(/\{(\w+)\}/) do
        name = Regexp.last_match(1)
        escape_path(params.key?(name) ? params[name] : params.fetch(name.to_sym))
      end
      q = URI.encode_www_form((query || {}).reject { |_, v| v.nil? })
      uri = URI(@base_url + path + (q.empty? ? "" : "?#{q}"))
      req = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri)
      req["Authorization"] = "Bearer #{@api_key}"
      req["Accept"] = "application/json"
      req["X-Workspace-Id"] = @workspace_id if @workspace_id && !@workspace_id.empty?
      unless body.nil?
        req.body = JSON.generate(body)
        req["Content-Type"] = "application/json"
      end
      # a retry with the same key never repeats the action
      req["Idempotency-Key"] = idempotency_key.to_s.empty? ? SecureRandom.uuid : idempotency_key if method != "GET"
      send_with_retries(uri, req)
    end

    # Yields every item of a list operation, following `nextCursor`. `operation` is the method name, e.g. :get_v1_profiles.
    # Without a block it returns an Enumerator.
    def paginate(operation, query: nil, path: nil, &block)
      return enum_for(:paginate, operation, query: query, path: path) unless block

      q = (query || {}).dup
      q.delete(:cursor)
      loop do
        page = public_send(operation, path: path, query: q) || {}
        (page["items"] || []).each(&block)
        cursor = page["nextCursor"]
        return if cursor.nil? || cursor == ""

        q["cursor"] = cursor
      end
    end

    private

    # Every call is safe to replay: a GET, or a non-GET carrying the same Idempotency-Key on every attempt.
    def send_with_retries(uri, req)
      attempt = 0
      loop do
        begin
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout, read_timeout: @timeout) { |http| http.request(req) }
        rescue *NETWORK_ERRORS
          raise if attempt >= @max_retries

          sleep(backoff(attempt))
          attempt += 1
          next
        end
        status = res.code.to_i
        if (status == 429 || status >= 500) && attempt < @max_retries
          sleep(retry_after(res["Retry-After"]) || backoff(attempt))
          attempt += 1
          next
        end
        text = res.body.to_s
        raise error_for(status, text) if status >= 300

        return text.empty? ? nil : JSON.parse(text)
      end
    end

    # Full jitter: a random wait up to 0.25 s * 2^attempt, capped at 8 s.
    def backoff(attempt)
      rand * [8.0, 0.25 * (2**attempt)].min
    end

    # Retry-After as delta-seconds or an HTTP date, in seconds; nil when absent or unparseable.
    def retry_after(value)
      return nil if value.nil? || value.empty?

      secs = Float(value, exception: false)
      return [secs, 0.0].max if secs

      [Time.httpdate(value) - Time.now, 0.0].max
    rescue ArgumentError
      nil
    end

    def escape_path(value)
      URI.encode_www_form_component(value.to_s).gsub("+", "%20") # form encoding turns spaces into "+"; a literal "+" is already %2B
    end

    def error_for(status, text)
      out = text.start_with?("{") ? (JSON.parse(text) rescue nil) : nil
      err = out.is_a?(Hash) && out["error"].is_a?(Hash) ? out["error"] : {}
      Error.new(status, err["code"] || "http_error", err["message"] || text[0, 200], err["details"])
    end
  end
end
