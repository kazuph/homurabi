# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/test'
require 'json'
require 'sinatra/base'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sinatra/inertia'

# Build a fresh Sinatra::Base subclass per test to keep state isolated.
def make_app(version: '1', encrypt_history: false, share: nil, csrf: false, &routes)
  Class.new(Sinatra::Base) do
    set :host_authorization, permitted_hosts: []   # Sinatra 4.x: disable host check for rack-test
    set :protection, except: %i[remote_token session_hijacking http_origin]
    set :inertia_csrf_protection, csrf
    register Sinatra::Inertia
    set :inertia_version, version
    set :inertia_encrypt_history, encrypt_history
    enable :sessions
    set :session_secret, 'a' * 64
    set :views, File.join(__dir__, 'test', 'views') if File.directory?(File.join(__dir__, 'test', 'views'))
    set :views, File.join(File.dirname(__FILE__), 'views')
    inertia_share(&share) if share
    instance_exec(&routes)
  end
end

# Minimal layout for the test apps.
LAYOUT_VIEWS = File.expand_path('views', __dir__)
FileUtils.mkdir_p LAYOUT_VIEWS unless File.directory?(LAYOUT_VIEWS)
File.write(File.join(LAYOUT_VIEWS, 'layout.erb'), <<~ERB)
  <!doctype html>
  <html><body>
    <div id="app" data-page="<%= @page_json %>"></div>
  </body></html>
ERB

class InertiaProtocolTest < Minitest::Test
  include Rack::Test::Methods

  def teardown
    @current_app = nil
  end

  def app
    @current_app
  end

  def with(app_klass, &)
    @current_app = app_klass
    instance_eval(&)
  end

  def test_initial_get_returns_html_with_data_page
    a = make_app do
      get('/') { inertia 'Hello', props: { name: 'world' } }
    end
    with(a) do
      get '/'
      assert_equal 200, last_response.status
      assert_includes last_response.headers['Content-Type'].to_s, 'text/html'
      assert_match(/<div id="app" data-page="/, last_response.body)
      assert_includes last_response.body, '&quot;component&quot;:&quot;Hello&quot;'
    end
  end

  def test_inertia_visit_returns_json
    a = make_app do
      get('/') { inertia 'Hello', props: { name: 'world' } }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      assert_equal 200, last_response.status
      assert_includes last_response.headers['Content-Type'].to_s, 'application/json'
      assert_equal 'true', last_response.headers['X-Inertia']
      page = JSON.parse(last_response.body)
      assert_equal 'Hello', page['component']
      assert_equal({ 'name' => 'world' }, page['props'])
      assert_equal '/', page['url']
      assert_equal '1', page['version']
    end
  end

  def test_version_mismatch_returns_409_with_location
    a = make_app(version: 'v2') do
      get('/') { inertia 'Hello', props: {} }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', 'v1'
      get '/foo?bar=1'
      assert_equal 409, last_response.status
      loc = last_response.headers['X-Inertia-Location']
      assert_includes loc, '/foo'
    end
  end

  def test_partial_reload_includes_only_requested_props
    a = make_app do
      get('/') do
        inertia 'Page', props: {
          a: -> { 'A' },
          b: -> { 'B' },
          c: -> { 'C' }
        }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      header 'X-Inertia-Partial-Component', 'Page'
      header 'X-Inertia-Partial-Data', 'a,c'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal({ 'a' => 'A', 'c' => 'C' }, page['props'])
    end
  end

  def test_always_prop_included_even_on_partial_that_omits_it
    a = make_app do
      get('/') do
        inertia 'Page', props: {
          a: -> { 'A' },
          token: Inertia.always { 'TOKEN' }
        }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      header 'X-Inertia-Partial-Component', 'Page'
      header 'X-Inertia-Partial-Data', 'a'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal({ 'a' => 'A', 'token' => 'TOKEN' }, page['props'])
    end
  end

  def test_defer_prop_excluded_from_initial_and_listed_in_deferredProps
    a = make_app do
      get('/') do
        inertia 'Page', props: {
          a: -> { 'A' },
          stats: Inertia.defer(group: 'meta') { 'STATS' }
        }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal({ 'a' => 'A' }, page['props'])
      assert_equal({ 'meta' => ['stats'] }, page['deferredProps'])
    end
  end

  def test_defer_prop_resolved_on_partial_request
    a = make_app do
      get('/') do
        inertia 'Page', props: {
          stats: Inertia.defer { 'STATS' }
        }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      header 'X-Inertia-Partial-Component', 'Page'
      header 'X-Inertia-Partial-Data', 'stats'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal({ 'stats' => 'STATS' }, page['props'])
      refute page.key?('deferredProps'), 'should not list resolved deferred props'
    end
  end

  def test_optional_prop_only_on_partial_request
    a = make_app do
      get('/') do
        inertia 'Page', props: {
          filter: Inertia.optional { 'F' }
        }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      refute page['props'].key?('filter'), 'optional prop omitted on initial visit'

      header 'X-Inertia-Partial-Component', 'Page'
      header 'X-Inertia-Partial-Data', 'filter'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal 'F', page['props']['filter']
    end
  end

  def test_merge_prop_listed_in_mergeProps
    a = make_app do
      get('/') do
        inertia 'Feed', props: {
          items: Inertia.merge([1, 2, 3])
        }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal [1, 2, 3], page['props']['items']
      assert_equal ['items'], page['mergeProps']
    end
  end

  def test_inertia_share_merges_into_every_response
    a = make_app(share: -> { { auth: { user: { id: 7, name: 'Alice' } } } }) do
      get('/') { inertia 'Page', props: { foo: 'bar' } }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal 'bar', page['props']['foo']
      assert_equal({ 'id' => 7, 'name' => 'Alice' }, page['props']['auth']['user'])
    end
  end

  def test_render_inertia_alias_works_like_inertia_helper
    a = make_app do
      get('/legacy') { render inertia: 'Legacy', props: { x: 1 } }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/legacy'
      page = JSON.parse(last_response.body)
      assert_equal 'Legacy', page['component']
      assert_equal({ 'x' => 1 }, page['props'])
    end
  end

  def test_render_component_with_kwargs_is_the_page_api
    a = make_app do
      get('/ideal') do
        render 'Ideal/Page',
               todos: -> { ['ship'] },
               stats: defer(group: 'meta') { { total: 1 } }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/ideal'
      page = JSON.parse(last_response.body)
      assert_equal 'Ideal/Page', page['component']
      assert_equal({ 'todos' => ['ship'] }, page['props'])
      assert_equal({ 'meta' => ['stats'] }, page['deferredProps'])
    end
  end

  def test_share_props_is_the_recommended_shared_props_dsl
    a = make_app do
      share_props { { auth: { user: 'Ruby' } } }
      get('/') { render 'Page', foo: 'bar' }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal 'bar', page['props']['foo']
      assert_equal 'Ruby', page['props']['auth']['user']
    end
  end

  def test_page_version_setting_drives_protocol_version
    a = make_app do
      set :page_version, -> { 'page-v2' }
      get('/') { render 'Page' }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', 'page-v2'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal 'page-v2', page['version']
    end
  end

  def test_page_error_and_history_helpers_alias_protocol_helpers
    a = make_app do
      put '/save' do
        page_errors title: 'is required'
        redirect '/form'
      end
      get '/form' do
        clear_history!
        encrypt_history!
        render 'Form'
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      put '/save'
      assert_equal 303, last_response.status

      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      follow_redirect!
      page = JSON.parse(last_response.body)
      assert_equal({ 'title' => 'is required' }, page['props']['errors'])
      assert_equal true, page['clearHistory']
      assert_equal true, page['encryptHistory']
    end
  end

  def test_errors_session_sweeps_after_one_render
    a = make_app do
      put '/save' do
        inertia_errors title: 'is required'
        redirect '/form'
      end
      get '/form' do
        inertia 'Form', props: {}
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      put '/save'
      assert_equal 303, last_response.status

      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      follow_redirect!
      page = JSON.parse(last_response.body)
      assert_equal({ 'title' => 'is required' }, page['props']['errors'])

      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/form'
      page = JSON.parse(last_response.body)
      refute page['props'].key?('errors'), 'errors should be swept after first render'
    end
  end

  def test_303_promotion_for_non_get_redirects
    a = make_app do
      put('/x') { redirect '/y' }   # 302 by default → middleware promotes to 303
      get('/y') { inertia 'Y', props: {} }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      put '/x'
      assert_equal 303, last_response.status
    end
  end

  def test_encrypt_history_flag
    a = make_app(encrypt_history: true) do
      get('/') { inertia 'Page', props: {} }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal true, page['encryptHistory']
    end
  end

  def test_clear_history_flag_per_route
    a = make_app do
      get('/') do
        inertia_clear_history!
        inertia 'Page', props: {}
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal true, page['clearHistory']
    end
  end

  # H-2 regression: per-route override of inertia_encrypt_history must
  # actually flip the response flag, even when the global setting is off.
  def test_encrypt_history_flag_per_route_override
    a = make_app(encrypt_history: false) do
      get('/') do
        inertia_encrypt_history!
        inertia 'Page', props: {}
      end
      get('/plain') do
        inertia 'Page', props: {}
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal true, page['encryptHistory'], 'override should take effect'

      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      get '/plain'
      page = JSON.parse(last_response.body)
      refute page.key?('encryptHistory'), 'plain route stays at global default'
    end
  end

  # H-1 regression: 303 promotion must NOT touch non-Inertia redirects so
  # plain REST endpoints sharing the app keep their original semantics.
  def test_303_promotion_skipped_for_non_inertia_requests
    a = make_app do
      put('/x') { redirect '/y' }
      get('/y') { 'ok' }
    end
    with(a) do
      put '/x'   # no X-Inertia header
      assert_equal 302, last_response.status
    end
  end

  def test_303_promotion_for_post_inertia_visits
    a = make_app do
      post('/x') { redirect '/y' }
      get('/y') { inertia 'Y', props: {} }
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      post '/x'
      assert_equal 303, last_response.status
    end
  end

  # H-3 regression: X-Inertia-Reset removes named props from the
  # outbound mergeProps array (the value is still emitted).
  def test_merge_reset_drops_key_from_mergeProps
    a = make_app do
      get('/') do
        inertia 'Feed', props: {
          items: Inertia.merge([1, 2, 3]),
          tags: Inertia.merge(['a', 'b'])
        }
      end
    end
    with(a) do
      header 'X-Inertia', 'true'
      header 'X-Inertia-Version', '1'
      header 'X-Inertia-Reset', 'items'
      get '/'
      page = JSON.parse(last_response.body)
      assert_equal [1, 2, 3], page['props']['items']
      assert_equal ['tags'], page['mergeProps']
    end
  end

  # C-1 regression: Inertia.once must not exist as a public API. The
  # protocol has no once-mode and the previous Prop class advertised
  # one-shot delivery without implementing it. Removed entirely.
  def test_once_constructor_is_not_part_of_public_api
    refute Sinatra::Inertia.respond_to?(:once),
           'Inertia.once was protocol-extraneous; it must not be exposed'
  end

  # H-4: CSRF middleware (double-submit XSRF-TOKEN cookie + X-XSRF-TOKEN
  # header) should be on by default and reject mismatched POSTs.
  def test_csrf_default_on_blocks_post_without_matching_header
    a = make_app(csrf: true) do
      post('/save') { 'ok' }
    end
    with(a) do
      # GET / first to receive an XSRF-TOKEN cookie
      get '/'
      cookie = last_response.headers['Set-Cookie'].to_s
      assert_match(/XSRF-TOKEN=([^;]+); Path=\/; SameSite=Lax/, cookie)
      token = cookie[/XSRF-TOKEN=([^;]+)/, 1]

      # POST without header → blocked
      header 'Cookie', "XSRF-TOKEN=#{token}"
      post '/save'
      assert_equal 403, last_response.status

      # POST with matching header → allowed
      header 'Cookie', "XSRF-TOKEN=#{token}"
      header 'X-XSRF-TOKEN', token
      post '/save'
      assert_equal 200, last_response.status
    end
  end

  def test_csrf_can_be_opted_out
    a = make_app(csrf: false) do
      post('/save') { 'ok' }
    end
    with(a) do
      post '/save'
      assert_equal 200, last_response.status
    end
  end

  def test_csrf_helper_returns_current_token
    a = make_app(csrf: true) do
      get('/token') { csrf_token.to_s }
    end
    with(a) do
      get '/token'
      assert_equal 200, last_response.status
      cookie = last_response.headers['Set-Cookie'].to_s
      cookie_token = cookie[/XSRF-TOKEN=([^;]+)/, 1]
      assert_equal cookie_token, last_response.body
    end
  end
end
