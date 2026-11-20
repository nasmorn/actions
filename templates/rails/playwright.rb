# frozen_string_literal: true

# Browser specs (spec/system, type: :system) drive Chromium with playwright-ruby-client
# directly: Playwright's locators and web-first assertions, no Capybara DSL. Capybara only
# boots the app in-process (Puma) through a null driver, so fabricators and transactional
# fixtures work as in any other spec. The Node driver is pinned in e2e/package.json.
#
# Template: nasmorn/actions templates/rails/playwright.rb (keep it identical across apps).
# Debug locally with HEADED=1 (visible browser) or PWDEBUG=1 (Playwright Inspector).
# A failing example keeps its trace: npx --prefix e2e playwright show-trace tmp/playwright/<example>.zip
require "capybara"
require "playwright"
require "playwright/test"

class CapybaraNullDriver < Capybara::Driver::Base
  def needs_server? = true
end
Capybara.register_driver(:null) { CapybaraNullDriver.new }

module PlaywrightBrowser
  CLI = Rails.root.join("e2e/node_modules/.bin/playwright-core").to_s
  TRACES = Rails.root.join("tmp/playwright")

  # Playwright's API is block-scoped; a Fiber keeps one browser open for the whole suite.
  # Started on first use, so runs without system specs don't need Node or Chromium.
  # A failed launch (no e2e/node_modules, Chromium not installed) is raised once per example
  # without retrying.
  def self.browser
    raise @launch_error if @launch_error

    @browser ||= begin
      @fiber = Fiber.new do
        Playwright.create(playwright_cli_executable_path: CLI) do |playwright|
          headless = ENV["HEADED"].blank? && ENV["PWDEBUG"].blank?
          playwright.chromium.launch(headless:) { |browser| Fiber.yield(browser) }
        end
      end
      @fiber.resume
    rescue StandardError => e
      @launch_error = e
      raise
    end
  end

  def self.stop!
    @fiber.resume if @fiber&.alive?
  end

  # example.exception isn't set yet for failures raised outside this hook's example.run:
  # Rails' teardown re-raising a server error ($!), and :aggregate_failures.
  def self.failed?(example)
    return true if example.exception || $!

    notifier = RSpec::Support.failure_notifier
    notifier.is_a?(RSpec::Expectations::FailureAggregator) &&
      (notifier.failures.any? || notifier.other_errors.any?)
  end

  def self.trace_path(example)
    name = example.full_description.parameterize.first(80)
    TRACES.join("#{name}-#{Digest::SHA1.hexdigest(example.id).first(8)}.zip")
  end

  # The Playwright page of the current example; `page` in specs and flows.
  def page = @playwright_page

  # Rails' failure screenshot would call Capybara's page; the trace has the screenshots.
  def take_failed_screenshot; end
end

Playwright::Test.expect_timeout = 5_000 # the gem's default, set here to be visible

RSpec.configure do |config|
  config.include PlaywrightBrowser, type: :system
  config.include Playwright::Test::Matchers, type: :system

  # Keeps rspec-rails from defaulting to driven_by(:selenium); the around hook below runs
  # before any before hook, so it sets the driver itself too.
  config.before(type: :system) { driven_by :null }
  # After hooks run before the fixture rollback: stop the page's JS here, and Rails'
  # Capybara.reset_sessions! then waits for Puma's pending requests.
  config.after(type: :system) { page&.goto("about:blank") }
  config.before(:suite) { FileUtils.rm_rf(PlaywrightBrowser::TRACES) } # only this run's traces
  config.after(:suite) { PlaywrightBrowser.stop! }

  config.around(type: :system) do |example|
    Capybara.current_driver = :null
    base_url = Capybara.current_session.server.base_url # boots Puma on first use

    # More context options per example, e.g. browser_context: { httpCredentials: {…} }
    options = example.metadata.fetch(:browser_context, {})
    PlaywrightBrowser.browser.new_context(baseURL: base_url, **options) do |context|
      context.set_default_timeout(10_000) # actions; Playwright's 30 s makes failures slow
      context.tracing.start(screenshots: true, snapshots: true, sources: true)
      @playwright_page = context.new_page
      example.run
    ensure
      if PlaywrightBrowser.failed?(example)
        path = PlaywrightBrowser.trace_path(example)
        context.tracing.stop(path: path.to_s)
        example.metadata[:extra_failure_lines] = Array(example.metadata[:extra_failure_lines]) +
                                                 ["Trace: #{path.relative_path_from(Rails.root)}"]
      else
        context.tracing.stop
      end
    end
  end
end
