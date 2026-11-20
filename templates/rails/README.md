# Rails browser specs (Playwright)

Browser specs in `spec/system/` drive Chromium with
[playwright-ruby-client](https://playwright-ruby-client.vercel.app/) directly: Playwright's
locators and web-first assertions in Ruby, no Capybara DSL. Capybara only boots the app
in-process, so fabricators/factories and transactional fixtures work as in other specs.

## Add to an app

1. `Gemfile`, group `:test`:
   ```ruby
   gem "capybara" # only boots the app server (Puma, which the app already has) for system specs
   gem "playwright-ruby-client", "~> 1.65.0", require: false # minor matches PLAYWRIGHT_VERSION
   ```
2. `e2e/package.json` from `package.json` here (replace `APP`), then `npm install --prefix e2e`
   and commit `e2e/package-lock.json`. Add `e2e/*` to `.dockerignore`; `**/node_modules/`
   to `.gitignore`.
3. `spec/support/playwright.rb` from `playwright.rb` here, unchanged, and make sure
   `spec/rails_helper.rb` requires `spec/support/**/*.rb`.
4. `bin/setup`: `npm ci --prefix e2e` and `e2e/node_modules/.bin/playwright install chromium`
   (once per checkout; without them every system spec fails to launch the browser).
5. CI: `with: browser: true` on `test-rails.yml`.

## Writing specs

```ruby
RSpec.describe "Checkout", type: :system do
  it "orders" do
    page.goto("/")
    page.get_by_role("button", name: "Zur Kasse").click
    page.get_by_label("E-Mail").fill("max@example.com")
    expect(page.get_by_test_id("cart-total")).to have_text("€ 49,90")
  end
end
```

- Locators: role, label, text first, then `data-testid`. No CSS/XPath in specs; if an element
  has no accessible name, give it one in the view (a `<label>`, `aria-label`, a named
  `fieldset`) and scope with `page.get_by_role("group", name: …)`.
- Repeated steps go into `spec/support/flows/` modules.
- Timeouts: 10 s per action (click, fill), 5 s per assertion (`expect(…).to have_text`).
- More options for an example's browser context through metadata, e.g. HTTP basic auth:
  `context "as admin", browser_context: { httpCredentials: { username: "admin", password: "secret" } }`.
- `HEADED=1` shows the browser, `PWDEBUG=1` opens the Playwright Inspector.
- A failing example keeps `tmp/playwright/<example>.zip`:
  `npx --prefix e2e playwright show-trace tmp/playwright/<example>.zip`.
  In CI it's the `playwright-traces` artifact of the run.

## Updating Playwright

All apps call `test-rails.yml@main`, and CI fails when an app's `e2e/package.json` pin isn't
exactly `PLAYWRIGHT_VERSION`. So bump app by app, without a red main anywhere:

1. In each app: bump the `playwright` pin in `e2e/package.json` (exact version) and
   `playwright-ruby-client` (its `COMPATIBLE_PLAYWRIGHT_VERSION` should match), and pass the
   new version in the workflow call (`PLAYWRIGHT_VERSION: "1.66.0"`) until step 2.
2. Bump the `PLAYWRIGHT_VERSION` default in `.github/workflows/test-rails.yml`.
3. Remove the `PLAYWRIGHT_VERSION:` override from the apps.
