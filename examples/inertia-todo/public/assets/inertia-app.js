// Inertia × Vue 3 client bootstrap.
// Loaded via <script type="module" src="/assets/inertia-app.js"></script>.
// importmap (Vue / @inertiajs/vue3 CDN) is declared in views/layout.erb.

import { createApp, h } from 'vue'
import { createInertiaApp } from '@inertiajs/vue3'

const Todos = {
  props: ['todos'],
  template: `<div class="page">
    <h1>Todos (Inertia × homura)</h1>
    <form @submit.prevent="submit">
      <input type="text" v-model="title" placeholder="やること" required>
      <button type="submit">追加</button>
    </form>
    <ul>
      <li v-for="t in todos" :key="t.id">
        <input type="checkbox" :checked="t.done" @change="toggle(t.id)">
        <span :style="t.done ? 'text-decoration:line-through;color:#888' : ''">{{ t.title }}</span>
        <button @click="del(t.id)">削除</button>
      </li>
    </ul>
    <p v-if="!todos.length" style="color:#888">まだTodoがありません</p>
  </div>`,
  data() { return { title: '' } },
  methods: {
    submit() {
      this.$inertia.post('/todos', { title: this.title }, {
        onSuccess: () => { this.title = '' }
      })
    },
    toggle(id) { this.$inertia.post(`/todos/${id}/toggle`) },
    del(id) { this.$inertia.post(`/todos/${id}/delete`) }
  }
}

const pages = { Todos }

createInertiaApp({
  // Inertia v1 expects `resolve` to return a Promise that yields the component.
  resolve: name => Promise.resolve(pages[name]),
  setup({ el, App, props, plugin }) {
    createApp({ render: () => h(App, props) }).use(plugin).mount(el)
  }
})
