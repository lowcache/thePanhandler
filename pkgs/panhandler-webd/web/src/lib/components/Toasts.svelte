<script lang="ts">
  import { toast } from '../toast.svelte';
</script>

<div class="toast-region" aria-live="polite" aria-atomic="true">
  {#each toast.toasts as item (item.id)}
    <div class="toast-item {item.type}" role="status">
      <div class="toast-indicator" aria-hidden="true"></div>
      <span class="toast-message">{item.message}</span>
      <button
        type="button"
        class="toast-dismiss"
        aria-label="Dismiss notification"
        onclick={() => toast.dismiss(item.id)}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
          <line x1="2" y1="2" x2="10" y2="10"></line>
          <line x1="10" y1="2" x2="2" y2="10"></line>
        </svg>
      </button>
    </div>
  {/each}
</div>

<style>
  .toast-region {
    position: fixed;
    bottom: var(--space-4);
    right: var(--space-4);
    z-index: 1000;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    max-width: 420px;
    width: calc(100vw - 2rem);
    pointer-events: none;
  }

  .toast-item {
    pointer-events: auto;
    display: flex;
    align-items: center;
    gap: var(--space-3);
    padding: var(--space-3) var(--space-4);
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    font-size: var(--font-size-sm);
    color: var(--color-text-primary);
  }

  .toast-indicator {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .toast-item.success .toast-indicator {
    background-color: var(--status-full);
  }

  .toast-item.error .toast-indicator {
    background-color: var(--status-error);
  }

  .toast-item.info .toast-indicator {
    background-color: var(--color-accent);
  }

  .toast-item.error {
    border-color: var(--status-error-border);
  }

  .toast-message {
    flex: 1;
    word-break: break-word;
  }

  .toast-dismiss {
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: none;
    color: var(--color-text-muted);
    cursor: pointer;
    padding: 2px;
    border-radius: var(--radius-sm);
    flex-shrink: 0;
  }

  .toast-dismiss:hover {
    color: var(--color-text-primary);
    background-color: var(--color-raised);
  }
</style>
