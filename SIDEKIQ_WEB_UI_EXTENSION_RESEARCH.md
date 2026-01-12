# Sidekiq Web UI Extension/Plugin Development Research

## Executive Summary

Sidekiq 7.3 and 8.0 provide a robust API for creating custom web UI extensions/tabs. The architecture emphasizes security (Content Security Policy with nonces), simplicity, and proper asset packaging within gems. This document covers everything needed to create professional Sidekiq web UI plugins.

---

## 1. Web UI Extension Architecture

### 1.1 Core Concepts

Sidekiq web UI extensions work by:
1. **Registering a class** with `Sidekiq::Web.configure`
2. **Defining HTTP routes** using the built-in router (Sinatra-style)
3. **Serving ERB templates** with access to helper methods
4. **Providing static assets** (CSS, JS) with proper CSP nonce handling

### 1.2 Registration API

The modern way to register extensions (Sidekiq 7.3+):

```ruby
# lib/my_gem/web.rb
require "sidekiq/web"

class MyExtension
  # Define routes in this class
  def self.registered(app)
    app.get "/custom_route" do
      @data = fetch_some_data
      erb :my_template, views: VIEWS
    end

    app.post "/custom_route/action" do
      handle_action
      redirect "#{root_path}custom_route"
    end
  end
end

# Register with Sidekiq::Web
Sidekiq::Web.configure do |config|
  config.register_extension(MyExtension,
    name: "my_extension",        # namespace for assets (required, no spaces)
    tab: "MyTab",                # tab label(s) shown in nav (string or array)
    index: "custom_route",       # route path(s) (string or array)
    root_dir: File.expand_path("../../web", __FILE__),  # directory containing assets/
    cache_for: 86400             # asset cache duration in seconds
  )
end
```

### 1.3 In config/routes.rb

```ruby
# Rails
require "sidekiq/web"
require "my_gem/web"  # IMPORTANT: Load extensions ONLY in web process

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"
end
```

⚠️ **Critical**: Never require web extensions in your Sidekiq initializer. They should ONLY be loaded in the web process, not in worker processes.

---

## 2. CSS/JavaScript Frameworks Used by Sidekiq

### 2.1 CSS Framework

**Sidekiq 8.0 removed Twitter Bootstrap** and built a custom CSS system:

- **No CSS framework** - custom CSS from scratch
- **CSS reduced from 160KB to 16KB** (90% reduction)
- **Page render time reduced from 55ms to 3ms**
- **CSS Custom Properties (CSS Variables)** for theming
- **OKLch color space** for modern color management
- **Dark mode support** via `prefers-color-scheme` media query

### 2.2 CSS Variables System

Sidekiq uses a comprehensive CSS variable system for theming:

```css
/* Light mode (default) */
:root {
  --color-primary: oklch(48% 0.2 13);
  --color-bg: oklch(99% 0.005 256);
  --color-elevated: oklch(100% 0 256);
  --color-border: oklch(95% 0.005 256);
  --color-input-border: oklch(90% 0.005 256);
  --color-selected: oklch(93% 0.005 256);
  --color-table-bg-alt: oklch(99% 0.005 256);
  --color-shadow: oklch(27% 0.005 256 / 5%);
  --color-text: oklch(27% 0.005 256);
  --color-text-light: oklch(52% 0.005 256);
  --color-success: oklch(from var(--color-primary) calc(l + 0.35) c calc(h + 120));
  --color-info: oklch(from var(--color-primary) calc(l + 0.35) c calc(h - 120));
  --color-danger: oklch(from var(--color-primary) calc(l + 0.35) c h);
  --color-warning: oklch(from var(--color-primary) calc(l + 0.35) c calc(h + 75));

  /* Spacing system */
  --space-1-2: 4px;
  --space: 8px;
  --space-2x: 16px;
  --space-3x: 24px;
  --space-4x: 32px;

  /* Typography */
  --font-sans: system-ui, sans-serif;
  --font-mono: ui-monospace, 'Cascadia Code', 'Source Code Pro', Menlo, Consolas, 'DejaVu Sans Mono', monospace;
  --font-size: 16px;
  --font-size-large: 1.728rem;
  --font-size-small: 0.833rem;
}

/* Dark mode */
@media (prefers-color-scheme: dark) {
  :root {
    --color-primary: oklch(65% 0.22 13);
    --color-bg: oklch(22% 0.01 256);
    --color-elevated: oklch(19% 0.01 256);
    --color-border: oklch(25% 0.01 256);
    /* ... and so on */
  }
}
```

### 2.3 OKLch Color Space

Sidekiq uses OKLch (Oklch) - a modern perceptually-uniform color space:

- **Lightness (L)**: 0-100%
- **Chroma (C)**: 0-0.4
- **Hue (H)**: 0-360 degrees

Benefits:
- Colors are consistent in darkness/lightness across hues
- Easy to dynamically adjust colors with `oklch(from ...)`
- Better accessibility and readability in both light/dark modes

### 2.4 Standard Components

Sidekiq's custom CSS includes:
- Navigation bar with active state indicators
- Buttons with multiple variants (`.btn`, `.btn-danger`, `.btn-warn`, `.btn-inverse`)
- Form controls with proper styling
- Tables with alternating rows and hover states
- Cards for statistics display
- Cards containers for flexible layouts
- Progress bars
- Labels and badges
- Alerts and notifications
- Pagination
- Responsive design (mobile-first, breakpoints at 800px, 1000px)

### 2.5 Extending Sidekiq's CSS

Create a static CSS file in your extension:

```
web/
  assets/
    my_extension/
      css/
        styles.css
```

Include it in your template:

```erb
<%= style_tag "my_extension/css/styles.css" %>
```

**Important CSS Rules**:
- Do NOT use inline `style=""` attributes in HTML
- Do NOT use `<style>` tags (CSP violation in 8.0)
- Use data attributes + JavaScript to dynamically set styles:

```erb
<!-- Do NOT do this -->
<div style="width: 50%">Bad</div>

<!-- Do this instead -->
<div class="widget" data-width="50">Good</div>

<!-- In JavaScript file -->
<script type="text/javascript" src="<%= root_path %>my_extension/js/init.js" nonce="<%= csp_nonce %>"></script>
```

```javascript
// web/assets/my_extension/js/init.js
document.querySelectorAll('.widget').forEach(el => {
  el.style.width = el.dataset.width + "%"
})
```

---

## 3. Graphing Libraries

### 3.1 Chart.js

**Library**: Chart.js (minified as `chart.min.js`)

Sidekiq uses Chart.js for all its metrics and dashboard visualization:

```javascript
// In Sidekiq's dashboard templates:
<script src="<%= root_path %>javascripts/chart.min.js" nonce="<%= csp_nonce %>"></script>
<script src="<%= root_path %>javascripts/chartjs-plugin-annotation.min.js" nonce="<%= csp_nonce %>"></script>
<script src="<%= root_path %>javascripts/chartjs-adapter-date-fns.min.js" nonce="<%= csp_nonce %>"></script>
```

### 3.2 Chart Classes in Sidekiq

Sidekiq wraps Chart.js with custom classes in `web/assets/javascripts/`:

#### BaseChart
```javascript
class BaseChart {
  constructor(el, options) {
    this.el = el;
    this.options = options;
    this.colors = new Colors();
  }

  init() {
    this.chart = new Chart(this.el, {
      type: this.options.chartType,
      data: { labels: this.options.labels, datasets: this.datasets },
      options: this.chartOptions,
    });
  }

  update() {
    this.chart.options = this.chartOptions;
    this.chart.update();
  }

  get chartOptions() {
    return {
      interaction: { mode: "nearest", axis: "x", intersect: false },
      scales: { x: { ticks: { autoSkipPadding: 10 } } },
      plugins: {
        legend: { display: false },
        annotation: { annotations: {} },
        tooltip: { animation: false }
      }
    };
  }
}
```

#### Colors Class (OKLch support)
```javascript
class Colors {
  constructor() {
    this.assignments = {};
    if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
      this.light = "65%";
      this.chroma = "0.15";
    } else {
      this.light = "48%";
      this.chroma = "0.2";
    }

    this.success = "oklch(" + this.light + " " + this.chroma + " 179)";
    this.failure = "oklch(" + this.light + " " + this.chroma + " 29)";
    this.fallback = "oklch(" + this.light + " 0.02 269)";
    this.primary = "oklch(" + this.light + " " + this.chroma + " 269)";

    this.available = [
      "oklch(" + this.light + " " + this.chroma + " 256)",
      "oklch(" + this.light + " " + this.chroma + " 196)",
      "oklch(" + this.light + " " + this.chroma + " 46)",
      // ... more colors for dataset rotation
    ];
  }

  checkOut(assignee) {
    const color = this.assignments[assignee] || this.available.shift() || this.fallback;
    this.assignments[assignee] = color;
    return color;
  }

  checkIn(assignee) {
    const color = this.assignments[assignee];
    delete this.assignments[assignee];
    if (color && color != this.fallback) {
      this.available.unshift(color);
    }
  }
}
```

### 3.3 Sidekiq's Built-in Chart Types

**DashboardChart** (line charts for real-time metrics):
- Shows processed and failed jobs over time
- Supports legend and cursor tracking
- Real-time polling updates

**JobMetricsOverviewChart** (multi-series line chart):
- Tracks execution time across multiple job classes
- Toggle visibility of individual series
- Supports time-based X-axis (using chartjs-adapter-date-fns)

**HistBubbleChart** (bubble chart for histograms):
- X-axis: time buckets
- Y-axis: execution time
- Bubble size: number of jobs
- Shows deployment markers

**HistTotalsChart** (bar chart):
- Distribution of job execution times
- X-axis: execution time buckets
- Y-axis: count of jobs

### 3.4 Using Charts in Extensions

To add charts to your extension:

```erb
<!-- web/views/my_view.html.erb -->
<%= script_tag "javascripts/chart.min.js" %>
<%= script_tag "javascripts/chartjs-plugin-annotation.min.js" %>
<%= script_tag "javascripts/base-charts.js" %>

<canvas id="my-chart">
  <%= to_json({
    processedLabel: t('Processed'),
    failedLabel: t('Failed'),
    labels: ["Hour 1", "Hour 2", "Hour 3"],
    processed: [100, 150, 200],
    failed: [5, 8, 3],
  }) %>
</canvas>

<script type="text/javascript" src="<%= root_path %>my_extension/js/my-chart.js" nonce="<%= csp_nonce %>"></script>
```

```javascript
// web/assets/my_extension/js/my-chart.js
var myChart = document.getElementById("my-chart");
if (myChart != null) {
  var chart = new DashboardChart(myChart, JSON.parse(myChart.textContent));
}
```

---

## 4. Routing and View Registration

### 4.1 Router API

Sidekiq::Web uses a **Sinatra-like routing system**:

```ruby
class MyExtension
  def self.registered(app)
    # GET request
    app.get "/my_page" do
      # env, request, response available
      # Access URL params with url_params("name")
      # Access route params with route_params(:id)
      @data = some_data
      erb :my_page, views: VIEWS
    end

    # POST request
    app.post "/my_page/action" do
      param = url_params("action")
      route_id = route_params(:id)

      # Do work...
      redirect_with_query("#{root_path}my_page")
    end

    # Dynamic route parameters
    app.get "/items/:id" do
      @item = fetch_item(route_params(:id))
      erb :item
    end

    # HEAD, PUT, PATCH, DELETE also supported
    app.delete "/items/:id" do
      delete_item(route_params(:id))
      redirect "#{root_path}items"
    end
  end
end
```

### 4.2 Parameter Handling

**Critical distinction** (Sidekiq 8.0):

```ruby
# Route parameters (from URL path)
route_params(:id)     # "123" from GET /items/123
route_params(:name)   # "foo" from GET /items/:name

# URL/Query parameters
url_params("page")    # "2" from GET /items?page=2
url_params("sort")    # "date" from POST data
```

This separation prevents URL parameter overrides in security-sensitive operations.

### 4.3 Available Helpers in Routes

All these are available in your routes thanks to `Sidekiq::Web::Action`:

```ruby
# Path helpers
root_path                          # "/sidekiq/" or similar
current_path                       # Current request path

# Rendering
erb(template_name, options)        # Render ERB template
render(:erb, string)               # Render string directly

# Request info
request                            # Rack::Request object
env                                # Rack env
response                           # Rack::Response

# Security
csp_nonce                          # CSP nonce for this request
h(text)                            # HTML escape text

# Localization
t("key")                           # Translate key
locale                             # Current locale
available_locales                  # List of locales

# Redirection
redirect(url)                      # HTTP redirect
redirect_with_query(url)           # Redirect preserving query params

# Formatting
number_with_delimiter(num)         # "1,234,567"
relative_time(time)                # "<time>" HTML element
format_memory(kb)                  # "123 MB" or "1.2 GB"

# Database access
Sidekiq.redis { |conn| ... }      # Access Redis
stats                              # Sidekiq::Stats instance
```

### 4.4 Tab Registration

Tabs appear in the navigation automatically:

```ruby
# Simple tab
tab: "MyTab"

# Multiple tabs (arrays)
tab: ["Tab1", "Tab2"],
index: ["route1", "route2"]  # Must match tab count
```

The tab label is shown in navigation with path `{root_path}{index}`.

---

## 5. Sidekiq 7 vs 8 Web UI Differences

### 5.1 Major Changes in Sidekiq 8.0

| Aspect | Sidekiq 7.x | Sidekiq 8.0 |
|--------|------------|-----------|
| **CSS Framework** | Bootstrap 160KB | Custom CSS 16KB |
| **CSS Approach** | class-based | CSS Variables + OKLch |
| **Page Load Time** | 55ms | 3ms |
| **CSP Nonce** | Optional | Required for all assets |
| **Inline CSS** | `<style>` allowed | Forbidden (CSP) |
| **Inline Scripts** | `<script>` allowed | Forbidden (CSP) |
| **Color Space** | hex/rgb | OKLch |
| **Dark Mode** | Limited support | Full support |
| **Extension Compatibility** | Partial | Full refactor needed |

### 5.2 Migration Guide: 7.x → 8.0

**Old way (Sidekiq 7.x):**
```erb
<!-- Old Bootstrap approach -->
<div class="container">
  <h1>My Page</h1>
  <div class="row">
    <div class="col-md-6">Content</div>
  </div>
</div>

<link href="/styles.css">
<script>
  // inline scripts were allowed
</script>
```

**New way (Sidekiq 8.0):**
```erb
<!-- New custom CSS approach -->
<div class="container">
  <section>
    <header><h1>My Page</h1></header>
    <!-- Use Sidekiq's CSS variables -->
  </section>
</div>

<%= style_tag "my_gem/css/styles.css" %>
<%= script_tag "my_gem/js/script.js" %>

<!-- In script.js, no inline code -->
```

### 5.3 CSP (Content Security Policy) Changes

**Sidekiq 8.0 CSP Header:**
```
default-src 'self' https: http:
script-src 'self' 'nonce-{random}'
style-src 'self' 'nonce-{random}'
img-src 'self' https: http: data:
```

**What this means:**
- All `<script>` tags MUST have `nonce="<%= csp_nonce %>"`
- All `<style>` tags are FORBIDDEN
- All JavaScript must be in separate files with nonce
- All CSS must be in separate files with nonce

**Use helper methods:**
```erb
<!-- CORRECT: Use helper methods -->
<%= script_tag "my_extension/js/init.js" %>
<%= style_tag "my_extension/css/styles.css" %>

<!-- WRONG: These will be blocked -->
<script nonce="<%= csp_nonce %>">/* code */</script>
<style nonce="<%= csp_nonce %>">/* css */</style>
```

### 5.4 Route Parameter Changes

Sidekiq 8.0 introduced strict parameter handling:

```ruby
# Sidekiq 7.x - flexible but less secure
get "/items/:id" do
  item_id = params[:id]  # Could be overridden by query string
end

# Sidekiq 8.0 - explicit parameter sources
get "/items/:id" do
  item_id = route_params(:id)  # ONLY from route, secure
  page = url_params("page")    # ONLY from query/form, explicit
end
```

---

## 6. Packaging Web UI Assets with a Ruby Gem

### 6.1 Directory Structure

```
my_sidekiq_extension/
├── lib/
│   ├── my_extension.rb              # Main gem file
│   └── my_extension/
│       └── web.rb                   # Web UI registration
├── web/
│   ├── assets/
│   │   └── my_extension/            # Namespaced assets
│   │       ├── css/
│   │       │   └── styles.css
│   │       ├── js/
│   │       │   ├── init.js
│   │       │   └── charts.js
│   │       └── images/
│   │           └── icon.png
│   ├── locales/
│   │   ├── en.yml
│   │   └── es.yml
│   └── views/
│       ├── index.html.erb
│       ├── detail.html.erb
│       └── _partial.html.erb
├── spec/
├── README.md
├── my_extension.gemspec
└── VERSION
```

### 6.2 Gemspec Configuration

```ruby
# my_extension.gemspec
Gem::Specification.new do |s|
  s.name          = "my_sidekiq_extension"
  s.version       = "1.0.0"
  s.authors       = ["Your Name"]
  s.email         = ["your@email.com"]
  s.summary       = "Sidekiq Web UI Extension"
  s.description   = "Custom Sidekiq Web UI tab"
  s.homepage      = "https://github.com/yourname/my_sidekiq_extension"
  s.license       = "MIT"

  s.files = Dir.glob("{lib,web}/**/*") + ["README.md", "LICENSE"]

  s.require_paths = ["lib"]

  s.add_dependency "sidekiq", ">= 7.3"
end
```

### 6.3 Web.rb Registration File

```ruby
# lib/my_extension/web.rb
require "sidekiq/web"

module MyExtension
  class Web
    ROOT = File.expand_path("../../web", File.dirname(__FILE__))
    VIEWS = File.expand_path("views", ROOT)

    def self.registered(app)
      # Define your routes here
      app.get "/my_extension" do
        @items = MyExtension.fetch_items
        erb :index, views: VIEWS
      end

      app.get "/my_extension/:id" do
        @item = MyExtension.fetch_item(route_params(:id))
        erb :detail, views: VIEWS
      end

      app.post "/my_extension/delete" do
        id = url_params("id")
        MyExtension.delete_item(id)
        redirect_with_query("#{root_path}my_extension")
      end
    end
  end
end

# Register the extension
Sidekiq::Web.configure do |config|
  config.register_extension(MyExtension::Web,
    name: "my_extension",
    tab: "My Extension",
    index: "my_extension",
    root_dir: MyExtension::Web::ROOT,
    asset_paths: ["css", "js", "images"],
    cache_for: 86400
  )
end
```

### 6.4 Asset Serving

Sidekiq automatically serves static files from `web/assets/{name}/{css,js,images,etc}/`:

```erb
<!-- In your template -->
<%= style_tag "my_extension/css/styles.css" %>
<%= script_tag "my_extension/js/init.js" %>

<!-- Images -->
<img src="<%= root_path %>my_extension/images/icon.png">
```

Files must be served via `style_tag` and `script_tag` helpers to get the CSP nonce.

### 6.5 Localization

Add locales in `web/locales/`:

```yaml
# web/locales/en.yml
en:
  MyExtensionKey: "My Extension Value"
  Items: "Items"
  Delete: "Delete"
```

Access in templates:
```erb
<h1><%= t('MyExtensionKey') %></h1>
```

Sidekiq automatically discovers and loads locale files from registered extensions.

### 6.6 Installation in User's App

```ruby
# Gemfile
gem "my_sidekiq_extension"

# config/routes.rb or config/initializers/sidekiq.rb
require "my_extension/web"  # IMPORTANT: Only load in web process!

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"
end
```

---

## 7. Code Examples

### 7.1 Minimal Extension Example

```ruby
# lib/my_extension/web.rb
require "sidekiq/web"

module MyExtension
  class Web
    ROOT = File.expand_path("../../web", File.dirname(__FILE__))
    VIEWS = File.expand_path("views", ROOT)

    def self.registered(app)
      app.get "/status" do
        @status = {
          uptime: Time.now.to_i,
          version: "1.0.0",
          timestamp: Time.now.utc.iso8601
        }
        erb :status, views: VIEWS
      end
    end
  end
end

Sidekiq::Web.configure do |config|
  config.register_extension(MyExtension::Web,
    name: "status",
    tab: "Status",
    index: "status",
    root_dir: MyExtension::Web::ROOT
  )
end
```

```erb
<!-- web/views/status.html.erb -->
<section>
  <header>
    <h1><%= t('Status') %></h1>
  </header>

  <div class="cards-container">
    <article>
      <h3><%= @status[:version] %></h3>
      <p><%= t('Version') %></p>
    </article>
    <article>
      <h3><%= @status[:uptime] %></h3>
      <p><%= t('Uptime') %></p>
    </article>
    <article>
      <h3><time><%= @status[:timestamp] %></time></h3>
      <p><%= t('Timestamp') %></p>
    </article>
  </div>
</section>
```

### 7.2 Extension with Chart

```erb
<!-- web/views/metrics.html.erb -->
<%= script_tag "javascripts/chart.min.js" %>
<%= script_tag "javascripts/base-charts.js" %>
<%= style_tag "my_extension/css/metrics.css" %>

<section>
  <header>
    <h1><%= t('Metrics') %></h1>
  </header>

  <canvas id="metrics-chart">
    <%= to_json({
      processedLabel: t('Processed'),
      failedLabel: t('Failed'),
      labels: @labels,
      processed: @processed,
      failed: @failed
    }) %>
  </canvas>
</section>

<%= script_tag "my_extension/js/metrics-chart.js" %>
```

```javascript
// web/assets/my_extension/js/metrics-chart.js
var chartEl = document.getElementById("metrics-chart");
if (chartEl) {
  var chart = new DashboardChart(chartEl, JSON.parse(chartEl.textContent));
}
```

```css
/* web/assets/my_extension/css/metrics.css */
canvas {
  background: var(--color-elevated);
  border: 1px solid var(--color-border);
  border-radius: 4px;
  margin: var(--space-2x) 0;
  padding: var(--space);
}
```

### 7.3 Extension with Forms

```erb
<!-- web/views/settings.html.erb -->
<section>
  <header>
    <h1><%= t('Settings') %></h1>
  </header>

  <form method="post" action="<%= root_path %>my_settings/save">
    <label for="interval">
      <%= t('Interval') %>:
      <input type="number" id="interval" name="interval" value="<%= @interval %>" class="form-control">
    </label>

    <label for="enabled">
      <input type="checkbox" id="enabled" name="enabled" <%= @enabled ? 'checked' : '' %>>
      <%= t('Enabled') %>
    </label>

    <button type="submit" class="btn btn-primary"><%= t('Save') %></button>
  </form>
</section>
```

```ruby
# In web.rb
app.post "/my_settings/save" do
  interval = url_params("interval").to_i
  enabled = url_params("enabled") == "on"

  MyExtension.save_settings(interval: interval, enabled: enabled)

  redirect_with_query("#{root_path}my_settings")
end
```

---

## 8. Best Practices for UI Consistency

### 8.1 Use Sidekiq's CSS Variables

```css
/* Good: Use CSS variables */
.my-card {
  background: var(--color-elevated);
  border: 1px solid var(--color-border);
  color: var(--color-text);
  padding: var(--space-2x);
}

.my-card:hover {
  background: var(--color-border);
  box-shadow: 0 2px 4px 0 var(--color-shadow);
}

/* Bad: Hardcoded colors */
.my-card {
  background: #ffffff;
  border: 1px solid #ddd;
  color: #333;
  padding: 16px;
}
```

### 8.2 Follow Sidekiq's Typography

```css
/* Match Sidekiq's type scale */
h1, h2, h3 {
  font-family: var(--font-sans);
  font-size: var(--font-size-large);
  font-weight: normal;
  margin: var(--space-3x) 0 var(--space);
}

body {
  font-family: var(--font-sans);
  font-size: var(--font-size);
  line-height: 1.5;
}

code {
  font-family: var(--font-mono);
  font-size: var(--font-size-small);
}
```

### 8.3 Reuse Sidekiq Component Classes

```erb
<!-- Buttons -->
<button class="btn"><%= t('Default') %></button>
<button class="btn btn-danger"><%= t('Delete') %></button>
<button class="btn btn-warn"><%= t('Warning') %></button>

<!-- Cards -->
<div class="cards-container">
  <article>
    <h3>Value</h3>
    <p>Label</p>
  </article>
</div>

<!-- Tables -->
<table>
  <thead>
    <tr><th>Column</th></tr>
  </thead>
  <tbody>
    <tr><td>Value</td></tr>
  </tbody>
</table>

<!-- Forms -->
<input type="text" class="form-control">
<select class="form-control">...</select>

<!-- Labels/Badges -->
<span class="label label-success">Success</span>
<span class="label label-danger">Danger</span>
<span class="label label-info">Info</span>
```

### 8.4 Responsive Design

Use Sidekiq's responsive breakpoints:

```css
/* Mobile first approach */
.my-layout {
  display: block;
}

/* Tablet and up (1000px) */
@media (min-width: 1000px) {
  .my-layout {
    display: flex;
    gap: var(--space-2x);
  }
}

/* Mobile devices (max 1000px) */
@media (max-width: 1000px) {
  .my-layout {
    flex-direction: column;
  }
}
```

### 8.5 Dark Mode Support

```css
/* Light mode (default) */
.my-card {
  color: var(--color-text);
  background: var(--color-elevated);
}

/* Dark mode automatically handled */
@media (prefers-color-scheme: dark) {
  :root {
    --color-text: oklch(75% 0.01 256);
    --color-elevated: oklch(19% 0.01 256);
  }
}
/* No additional CSS needed if using variables! */
```

### 8.6 Spacing System

```css
/* Stick to the spacing system */
.my-component {
  margin: var(--space-3x) 0 var(--space);      /* margin-top: 24px, margin-bottom: 8px */
  padding: var(--space-2x);                     /* 16px all around */
  gap: var(--space);                            /* 8px gap between items */
}

/* Spacing scale: 4px, 8px, 16px, 24px, 32px */
```

---

## 9. Real-World Example: Redis Info Extension

Sidekiq includes an example extension showing best practices:

**Path**: `examples/webui-ext` in Sidekiq source

Key files:
- `lib/sidekiq-redis_info/web.rb` - Registration
- `web/views/redis_info.html.erb` - Template
- `web/assets/redis_info/css/ext.css` - Styles
- `web/assets/redis_info/js/ext.js` - JavaScript

```ruby
# lib/sidekiq-redis_info/web.rb
require "sidekiq-redis_info"
require "sidekiq/web"

class SidekiqExt::RedisInfo::Web
  ROOT = File.expand_path("../../web", File.dirname(__FILE__))
  VIEWS = File.expand_path("views", ROOT)

  def self.registered(app)
    app.get "/redis_info" do
      @info = SidekiqExt::RedisInfo.new
      erb(:redis_info, views: VIEWS)
    end
  end
end

Sidekiq::Web.configure do |config|
  config.register_extension(SidekiqExt::RedisInfo::Web,
    name: "redis_info",
    tab: ["Redis"],
    index: ["redis_info"],
    root_dir: SidekiqExt::RedisInfo::Web::ROOT,
    asset_paths: ["css", "js"])
end
```

---

## 10. Security Considerations

### 10.1 XSS Prevention

✅ **Safe**:
```erb
<!-- Use h() helper to escape -->
<%= h @user_input %>

<!-- Use helpers for special content -->
<%= relative_time(@time) %>
<%= number_with_delimiter(@num) %>
```

❌ **Unsafe**:
```erb
<!-- Never trust user input -->
<%= @user_input %>
<%= raw(@html) %>
```

### 10.2 CSRF Protection

Sidekiq 8.0 handles CSRF automatically for forms. Include method in form:

```erb
<form method="post" action="...">
  <!-- CSRF token is automatically included -->
</form>
```

### 10.3 CSP Compliance

All assets must use the `style_tag` and `script_tag` helpers:

```erb
<!-- CORRECT -->
<%= style_tag "my_extension/css/styles.css" %>
<%= script_tag "my_extension/js/init.js" %>

<!-- WRONG - Will be blocked -->
<link href="/styles.css">
<script src="/init.js"></script>
<style>/* code */</style>
<script>/* code */</script>
```

### 10.4 Parameter Validation

Always validate parameters:

```ruby
app.post "/items/delete" do
  id = url_params("id")

  # Validate before using
  raise "Invalid ID" unless id =~ /^\d+$/

  MyExtension.delete_item(id)
  redirect "#{root_path}items"
end
```

---

## 11. Testing Checklist

- [ ] Works in Sidekiq 7.3.x
- [ ] Works in Sidekiq 8.0+
- [ ] CSS uses variables, not hardcoded colors
- [ ] No inline `<style>` tags
- [ ] No inline `<script>` tags
- [ ] All scripts use `nonce` via `script_tag`
- [ ] All stylesheets use `nonce` via `style_tag`
- [ ] Dark mode appearance is acceptable
- [ ] Responsive design works on mobile
- [ ] Forms are secure (CSRF, input validation)
- [ ] XSS protection (escaped output)
- [ ] User input is properly HTML-escaped
- [ ] Charts render correctly with Chart.js
- [ ] Localization strings are used
- [ ] Gem files include assets in `files`

---

## Summary

Creating Sidekiq web UI extensions requires understanding:

1. **Architecture**: Use `Sidekiq::Web.configure` and `register_extension` API
2. **CSS**: Custom CSS with CSS variables and OKLch colors (no Bootstrap)
3. **Charts**: Chart.js with Sidekiq's wrapper classes
4. **Routing**: Sinatra-like routes with strict parameter handling
5. **Assets**: Static files served with CSP nones via helpers
6. **Security**: XSS/CSRF prevention, Content Security Policy compliance
7. **Compatibility**: Support both Sidekiq 7.3 and 8.0+ with their differences

The key success factor is understanding the **migration from Bootstrap (7.x) to custom CSS (8.0)** and the **strict CSP requirements** that make 8.0 immune to XSS attacks.
