# Hermetica Ruby client

Generated from the Hermetica OpenAPI spec (2041 operations). Ruby 3.0+, standard library only (net/http, json).

## Install

```sh
gem install hermeticacomms
```

or in a Gemfile: `gem "hermeticacomms", "~> 0.1.0"`.

## Quick start

```ruby
require "hermetica"

hm = Hermetica::Client.new("hm_sk_...", base_url: "https://api.example.com")
page = hm.get_v1_profiles(query: { limit: 25 })
hm.post_v1_events(body: { name: "signed_up", profile: { email: "ada@example.com" } }, idempotency_key: "signup-ada-1")
```

One method per operationId, snake_case. Keyword arguments: `path:` (path params), `query:`, `body:`, `idempotency_key:`.
Results are parsed JSON (Hash/Array with string keys). Pass `workspace_id:` to `Client.new` to send `X-Workspace-Id`.

## Paging

```ruby
hm.paginate(:get_v1_profiles, query: { limit: 100 }) { |profile| puts profile["id"] }
hm.paginate(:get_v1_profiles).first(10) # an Enumerator without a block
```

`paginate` follows `nextCursor` until it is empty and yields every entry of `items`.

## Idempotency

Every non-GET call sends an `Idempotency-Key` (a random UUID unless you pass `idempotency_key:`).

## Retries

Network errors, 429 and 5xx are retried automatically with exponential backoff and jitter, honouring `Retry-After`. Every attempt of
a call sends the same `Idempotency-Key`, so a retried write never runs twice. `Client.new(..., max_retries: 3)` is the default;
`max_retries: 0` turns retries off. When you retry a failed call yourself, pass the same `idempotency_key:`.

## Errors

Any non-2xx answer raises `Hermetica::Error` with `status`, `code`, `error_message` and `details` (`message` is
"status code: error_message"). Network failures, once retries run out, raise the usual Net::HTTP / Socket errors.

```ruby
begin
  hm.get_v1_profiles_by_id(path: { id: "missing" })
rescue Hermetica::Error => e
  warn "#{e.status} #{e.code}: #{e.error_message}"
end
```

Consent and suppression are enforced by the API; the client cannot bypass them.
