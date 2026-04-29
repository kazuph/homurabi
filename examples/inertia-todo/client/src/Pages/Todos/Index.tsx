import { Head, useForm, usePage, router, Deferred } from '@inertiajs/react';
import { useEffect } from 'react';
import type { TodosIndexProps } from '../../types';
import { TodoFormSchema, validate } from '../../schemas';

export default function TodosIndex({ todos, stats }: TodosIndexProps) {
  const { props } = usePage<TodosIndexProps>();
  const flash = props.flash ?? {};
  const serverErrors = props.errors ?? {};

  const form = useForm({
    title: flash.values?.title ?? '',
    description: flash.values?.description ?? '',
  });

  // If the server stamped errors into props (after validation redirect),
  // copy them into the local form so the input fields highlight properly.
  useEffect(() => {
    const entries = Object.entries(serverErrors);
    if (entries.length > 0) {
      for (const [field, message] of entries) {
        form.setError(field as keyof typeof form.data, message);
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(serverErrors)]);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const clientErrors = validate(TodoFormSchema, form.data);
    const clientEntries = Object.entries(clientErrors) as Array<[keyof typeof form.data, string]>;
    if (clientEntries.length > 0) {
      for (const [field, message] of clientEntries) form.setError(field, message);
      return;
    }
    form.post('/todos', {
      onSuccess: () => form.reset('title', 'description'),
      preserveScroll: true,
    });
  }

  function toggle(id: number) {
    router.post(`/todos/${id}/toggle`, {}, { preserveScroll: true });
  }
  function destroy(id: number) {
    router.post(`/todos/${id}/delete`, {}, { preserveScroll: true });
  }

  return (
    <div className="page">
      <Head title="Inertia × homura Todo" />
      <h1>Todos (sinatra-inertia × React)</h1>

      {flash.notice && <div className="flash notice">{flash.notice}</div>}
      {flash.alert && <div className="flash alert">{flash.alert}</div>}

      <form className="todo-form" onSubmit={handleSubmit} noValidate>
        <label htmlFor="title">タイトル</label>
        <input
          id="title"
          type="text"
          value={form.data.title}
          onChange={(e) => form.setData('title', e.target.value)}
          aria-invalid={Boolean(form.errors.title)}
          aria-describedby={form.errors.title ? 'title-error' : undefined}
          placeholder="やること"
        />
        {form.errors.title && (
          <div id="title-error" className="error" role="alert">{form.errors.title}</div>
        )}

        <label htmlFor="description">メモ（任意）</label>
        <textarea
          id="description"
          rows={2}
          value={form.data.description}
          onChange={(e) => form.setData('description', e.target.value)}
          aria-invalid={Boolean(form.errors.description)}
          aria-describedby={form.errors.description ? 'description-error' : undefined}
          placeholder="補足があれば"
        />
        {form.errors.description && (
          <div id="description-error" className="error" role="alert">{form.errors.description}</div>
        )}

        <button type="submit" disabled={form.processing}>追加</button>
      </form>

      <Deferred data="stats" fallback={<div className="stats">統計を読み込み中…</div>}>
        {stats && (
          <div className="stats" data-testid="stats">
            <span><strong>{stats.total}</strong>件</span>
            <span>完了 <strong>{stats.done}</strong></span>
            <span>未完了 <strong>{stats.pending}</strong></span>
          </div>
        )}
      </Deferred>

      {todos.length === 0 ? (
        <div className="empty">まだTodoがありません</div>
      ) : (
        <ul className="todo-list">
          {todos.map((t) => (
            <li key={t.id}>
              <input type="checkbox" checked={t.done} onChange={() => toggle(t.id)} aria-label={`${t.title}を${t.done ? '未完了' : '完了'}に`} />
              <div>
                <div className={`title ${t.done ? 'done' : ''}`}>{t.title}</div>
                {t.description && <div className="description">{t.description}</div>}
              </div>
              <button className="delete-btn" onClick={() => destroy(t.id)} aria-label={`${t.title}を削除`}>削除</button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
