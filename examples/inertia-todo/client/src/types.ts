export type Todo = {
  id: number;
  title: string;
  description: string | null;
  done: boolean;
  created_at: number;
};

export type Stats = {
  total: number;
  done: number;
  pending: number;
};

export type Flash = {
  notice?: string;
  alert?: string;
  values?: { title?: string; description?: string };
};

export type SharedProps = {
  flash: Flash;
  csrfToken: string;
  errors?: Record<string, string>;
};

export type TodosIndexProps = SharedProps & {
  todos: Todo[];
  stats?: Stats; // deferred — present after second roundtrip
};
