import { createInertiaApp } from '@inertiajs/react';
import { createRoot, hydrateRoot } from 'react-dom/client';
import { StrictMode } from 'react';
import './styles.css';

createInertiaApp({
  resolve: async (name) => {
    const pages = import.meta.glob('./Pages/**/*.tsx', { eager: false });
    const key = `./Pages/${name}.tsx`;
    const importer = pages[key];
    if (!importer) throw new Error(`Inertia page not found: ${name} (looked at ${key})`);
    const mod = (await importer()) as { default: unknown };
    return mod.default as never;
  },
  setup({ el, App, props }) {
    if (el.hasChildNodes()) {
      hydrateRoot(el, <StrictMode><App {...props} /></StrictMode>);
    } else {
      createRoot(el).render(<StrictMode><App {...props} /></StrictMode>);
    }
  },
  progress: { color: '#4f46e5' },
});
