# Quick Reference: Sidekiq Web UI Extension Development

## TL;DR - Key Points

### Registration
```ruby
Sidekiq::Web.configure do |config|
  config.register_extension(MyExtension,
    name: "my_extension",      # namespace
    tab: "TabName",            # tab label
    index: "route_path",       # route path
    root_dir: __dir__ + "/../web"
  )
end
```

### Routing
```ruby
class MyExtension
  def self.registered(app)
    app.get "/my_route" do
      @data = fetch_data
      erb :template, views: VIEWS
    end
  end
end
```

### CSS/JS
- **CSS Framework**: Custom CSS with OKLch colors (no Bootstrap)
- **Charts**: Chart.js with Sidekiq wrapper classes
- **Use Helpers**: `style_tag` and `script_tag` for CSP nonce compliance
- **No inline CSS/JS**: All code must be in separate files (Sidekiq 8.0 requirement)

### Asset Structure
```
web/
  assets/
    my_extension/
      css/styles.css
      js/init.js
  views/
    index.html.erb
  locales/
    en.yml
```

### Templates
```erb
<%= style_tag "my_extension/css/styles.css" %>
<%= script_tag "my_extension/js/init.js" %>

<section>
  <header><h1><%= t('Title') %></h1></header>
  <div class="cards-container">
    <article>
      <h3><%= @value %></h3>
      <p><%= t('Label') %></p>
    </article>
  </div>
</section>
```

### CSS Variables
```css
/* Light/dark mode handled automatically */
.my-component {
  color: var(--color-text);
  background: var(--color-elevated);
  border: 1px solid var(--color-border);
  padding: var(--space-2x);
  gap: var(--space);
}
```

## Sidekiq 7 vs 8 Key Differences

| Feature | 7.x | 8.0 |
|---------|-----|-----|
| CSS | Bootstrap | Custom CSS |
| CSP | Optional | **Required** |
| Inline Code | Allowed | **Forbidden** |
| Colors | Hex/RGB | OKLch |
| Performance | 55ms | 3ms |

## Security Critical

✅ Always use:
- `h()` to escape user input
- `style_tag()` and `script_tag()` helpers
- `route_params()` for URL path params
- `url_params()` for query/form params

❌ Never:
- Use inline `<style>` tags
- Use inline `<script>` tags
- Trust unsanitized user input
- Load extensions in worker processes

## Charting Example

```erb
<canvas id="my-chart">
  <%= to_json({ processed: [100, 150], failed: [5, 8] }) %>
</canvas>
<%= script_tag "my_extension/js/chart.js" %>
```

```javascript
// web/assets/my_extension/js/chart.js
const el = document.getElementById("my-chart");
if (el) {
  const chart = new DashboardChart(el, JSON.parse(el.textContent));
}
```

## See Full Documentation

→ **SIDEKIQ_WEB_UI_EXTENSION_RESEARCH.md** for complete details
