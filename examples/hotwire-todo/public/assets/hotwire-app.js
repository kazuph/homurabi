// hotwire-todo client entrypoint.
// Loaded by views/layout.erb as `<script type="module" src="/assets/hotwire-app.js">`.
// The CDN URL mappings live in the inline <script type="importmap"> in layout.erb.

import '@hotwired/turbo'
import { Application, Controller } from '@hotwired/stimulus'

const app = Application.start()

app.register('todoform', class extends Controller {
  connect() {
    this.element.querySelector('input[name=title]')?.focus()
  }
})
