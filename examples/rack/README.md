# Rack-only example

Smallest homura app that uses Rack directly, without requiring Sinatra.

```ruby
run ->(env) {
  [200, { 'content-type' => 'text/plain; charset=utf-8' }, ["hello\n"]]
}
```

## Run

```bash
bundle install
npm install
bundle exec rake build
bundle exec rake dev
```

## Deploy

```bash
bundle exec rake deploy
```
