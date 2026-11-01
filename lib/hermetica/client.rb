# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
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

    attr_reader :api_key, :base_url, :workspace_id, :timeout

    def initialize(api_key, base_url: "http://localhost:4000", workspace_id: nil, timeout: 30)
      @api_key = api_key
      @base_url = base_url.sub(%r{/+\z}, "")
      @workspace_id = workspace_id
      @timeout = timeout
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
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout, read_timeout: @timeout) { |http| http.request(req) }
      text = res.body.to_s
      status = res.code.to_i
      raise error_for(status, text) if status >= 300

      text.empty? ? nil : JSON.parse(text)
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
