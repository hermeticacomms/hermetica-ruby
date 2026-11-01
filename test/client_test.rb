# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "hermetica"

class ClientTest < Minitest::Test
  # Stands in for a Net::HTTP connection: records each request and answers from a queue.
  class FakeHTTP
    attr_reader :requests, :starts

    def initialize(*responses)
      @responses = responses
      @requests = []
      @starts = []
    end

    def start(*args, **kw)
      @starts << [args, kw]
      yield self
    end

    def request(req)
      @requests << req
      code, body, headers = @responses.shift
      raise code if code.is_a?(Class)

      res = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "")
      (headers || {}).each { |k, v| res[k] = v }
      res.instance_variable_set(:@body, body)
      res.instance_variable_set(:@read, true)
      res
    end
  end

  def with_http(*responses)
    fake = FakeHTTP.new(*responses)
    Net::HTTP.stub(:start, ->(*args, **kw, &blk) { fake.start(*args, **kw, &blk) }) { yield fake }
    fake
  end

  def client(**opts)
    Hermetica::Client.new("hm_sk_test", base_url: "https://api.example.com/", **opts)
  end

  def test_get_sends_auth_query_and_no_idempotency_key
    fake = with_http([200, '{"items":[]}']) do
      assert_equal({ "items" => [] }, client(workspace_id: "ws_1").request("GET", "/v1/things", query: { limit: 5, skip: nil, tag: %w[a b] }))
    end
    req = fake.requests.first
    assert_equal "GET", req.method
    assert_equal "/v1/things?limit=5&tag=a&tag=b", req.path
    assert_equal "Bearer hm_sk_test", req["Authorization"]
    assert_equal "ws_1", req["X-Workspace-Id"]
    assert_nil req["Idempotency-Key"]
    assert_equal [["api.example.com", 443], { use_ssl: true, open_timeout: 30, read_timeout: 30 }], fake.starts.first
  end

  def test_post_sends_json_body_and_idempotency_key
    fake = with_http([201, ""], [201, ""]) do
      c = client
      assert_nil c.request("POST", "/v1/things/{id}", path_params: { id: "a b/c" }, body: { "x" => 1 })
      c.request("POST", "/v1/things/{id}", path_params: { "id" => "1" }, body: {}, idempotency_key: "key-1")
    end
    first, second = fake.requests
    assert_equal "/v1/things/a%20b%2Fc", first.path
    assert_equal '{"x":1}', first.body
    assert_equal "application/json", first["Content-Type"]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, first["Idempotency-Key"])
    assert_equal "key-1", second["Idempotency-Key"]
  end

  def test_missing_path_param_raises
    assert_raises(KeyError) { client.request("GET", "/v1/things/{id}") }
  end

  def test_error_carries_status_code_message_details
    err = nil
    with_http([404, '{"error":{"code":"not_found","message":"No such thing","details":{"id":"x"}}}']) do
      err = assert_raises(Hermetica::Error) { client.request("GET", "/v1/things") }
    end
    assert_equal [404, "not_found", "No such thing", { "id" => "x" }], [err.status, err.code, err.error_message, err.details]
    assert_equal "404 not_found: No such thing", err.message
  end

  def test_non_json_error_falls_back_to_http_error
    err = nil
    with_http([502, "Bad gateway"]) { err = assert_raises(Hermetica::Error) { client(max_retries: 0).request("DELETE", "/v1/x") } }
    assert_equal [502, "http_error", "Bad gateway", nil], [err.status, err.code, err.error_message, err.details]
  end

  def test_retries_5xx_429_and_network_errors_with_the_same_key
    out = nil
    fake = with_http([503, "", { "Retry-After" => "0" }], [429, "", { "Retry-After" => "0" }], [Errno::ECONNRESET], [200, '{"ok":true}']) do
      out = client.request("POST", "/v1/x", body: { "a" => 1 })
    end
    assert_equal({ "ok" => true }, out)
    assert_equal 4, fake.requests.size
    keys = fake.requests.map { |r| r["Idempotency-Key"] }
    assert_equal 1, keys.uniq.size
    refute_nil keys.first
    assert_equal ['{"a":1}'] * 4, fake.requests.map(&:body)
  end

  def test_gives_up_after_max_retries
    err = nil
    fake = with_http([502, "a", { "Retry-After" => "0" }], [502, "b", { "Retry-After" => "0" }]) do
      err = assert_raises(Hermetica::Error) { client(max_retries: 1).request("GET", "/v1/x") }
    end
    assert_equal [502, "b"], [err.status, err.error_message]
    assert_equal 2, fake.requests.size
  end

  def test_does_not_retry_4xx
    fake = with_http([404, "{}"], [200, "{}"]) do
      assert_raises(Hermetica::Error) { client.request("GET", "/v1/x") }
    end
    assert_equal 1, fake.requests.size
  end

  def test_network_error_raises_once_retries_run_out
    fake = with_http([Errno::ECONNREFUSED]) do
      assert_raises(Errno::ECONNREFUSED) { client(max_retries: 0).request("GET", "/v1/x") }
    end
    assert_equal 1, fake.requests.size
  end

  def test_retry_after_parsing
    c = client
    assert_equal 2.0, c.send(:retry_after, "2")
    assert_equal 0.0, c.send(:retry_after, "-1")
    assert_equal 0.0, c.send(:retry_after, "Wed, 21 Oct 2015 07:28:00 GMT")
    assert_in_delta 5.0, c.send(:retry_after, (Time.now + 5).httpdate), 1.5
    assert_nil c.send(:retry_after, "soon")
    assert_nil c.send(:retry_after, nil)
  end

  def test_paginate_follows_next_cursor
    items = nil
    fake = with_http([200, '{"items":[1,2],"nextCursor":"c2"}'], [200, '{"items":[3],"nextCursor":null}']) do
      items = client.paginate(:request_page, query: { limit: 2 }).to_a
    end
    assert_equal [1, 2, 3], items
    assert_equal ["/v1/p?limit=2", "/v1/p?limit=2&cursor=c2"], fake.requests.map(&:path)
  end

  def test_generated_operations_exist
    assert Hermetica::Client.method_defined?(:get_healthz)
    assert_equal Hermetica::VERSION, Gem::Specification.load(File.expand_path("../hermeticacomms.gemspec", __dir__)).version.to_s
  end
end

# A list operation for the paging test, shaped like a generated one.
module Hermetica
  class Client
    def request_page(path: nil, query: nil)
      request("GET", "/v1/p", path_params: path, query: query)
    end
  end
end
