import { z } from 'zod';

export const TodoFormSchema = z.object({
  title: z
    .string()
    .min(1, 'タイトルは必須です')
    .max(40, '40文字以内で入力してください'),
  description: z
    .string()
    .max(200, '200文字以内で入力してください')
    .optional()
    .or(z.literal('')),
});

export type TodoFormValues = z.infer<typeof TodoFormSchema>;

export type FormErrors<T> = Partial<Record<keyof T, string>>;

export function validate<T>(schema: z.ZodSchema<T>, values: unknown): FormErrors<T> {
  const result = schema.safeParse(values);
  if (result.success) return {};
  const out: FormErrors<T> = {};
  for (const issue of result.error.issues) {
    const key = issue.path[0] as keyof T;
    if (key && !out[key]) out[key] = issue.message;
  }
  return out;
}
