export interface Toast {
  id: string;
  type: 'info' | 'success' | 'error';
  message: string;
  durationMs?: number;
}

class ToastStore {
  toasts = $state<Toast[]>([]);

  add(message: string, type: 'info' | 'success' | 'error' = 'info', durationMs = 5000): string {
    const id = Math.random().toString(36).substring(2, 9);
    const item: Toast = { id, type, message, durationMs };
    this.toasts = [...this.toasts, item];

    if (durationMs > 0) {
      setTimeout(() => {
        this.dismiss(id);
      }, durationMs);
    }
    return id;
  }

  success(message: string, durationMs = 5000): string {
    return this.add(message, 'success', durationMs);
  }

  error(message: string, durationMs = 8000): string {
    return this.add(message, 'error', durationMs);
  }

  info(message: string, durationMs = 5000): string {
    return this.add(message, 'info', durationMs);
  }

  dismiss(id: string): void {
    this.toasts = this.toasts.filter((t) => t.id !== id);
  }

  clear(): void {
    this.toasts = [];
  }
}

export const toast = new ToastStore();
