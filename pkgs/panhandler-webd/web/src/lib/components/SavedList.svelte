<script lang="ts">
  import type { SavedNetwork } from '../api';

  let {
    savedNetworks = [],
    isLoading = false,
    onConnect,
    onForget,
  }: {
    savedNetworks: SavedNetwork[];
    isLoading?: boolean;
    onConnect: (network: SavedNetwork) => void;
    onForget: (ssid: string) => Promise<void>;
  } = $props();

  let confirmingSsid = $state<string | null>(null);
  let confirmTimer = $state<ReturnType<typeof setTimeout> | null>(null);
  let isForgetting = $state<string | null>(null);

  function startForgetConfirm(ssid: string) {
    if (confirmTimer) {
      clearTimeout(confirmTimer);
    }
    confirmingSsid = ssid;
    confirmTimer = setTimeout(() => {
      confirmingSsid = null;
      confirmTimer = null;
    }, 4000);
  }

  async function handleForget(ssid: string) {
    if (confirmTimer) {
      clearTimeout(confirmTimer);
      confirmTimer = null;
    }
    confirmingSsid = null;
    try {
      isForgetting = ssid;
      await onForget(ssid);
    } finally {
      isForgetting = null;
    }
  }

  function cancelConfirm() {
    if (confirmTimer) {
      clearTimeout(confirmTimer);
      confirmTimer = null;
    }
    confirmingSsid = null;
  }
</script>

<div class="card saved-card">
  <div class="card-header">
    <div class="header-title-group">
      <h2 class="card-title">Saved Networks</h2>
      <span class="count-badge font-mono">{savedNetworks.length}</span>
    </div>
  </div>

  {#if isLoading && savedNetworks.length === 0}
    <div class="loading-state">
      <div class="skeleton-row skeleton"></div>
      <div class="skeleton-row skeleton"></div>
    </div>
  {:else if savedNetworks.length === 0}
    <div class="empty-state">
      <p>No saved Wi-Fi profiles found.</p>
    </div>
  {:else}
    <ul class="saved-list" role="list">
      {#each savedNetworks as item (item.id || item.ssid)}
        <li class="saved-item">
          <div class="saved-info">
            <span class="saved-ssid font-mono">{item.ssid}</span>
            <div class="saved-badges">
              <span class="badge badge-storage-{item.storage}">
                {item.storage}
              </span>
              {#if item.protected}
                <span class="protected-indicator" title="Protected profile (cannot be forgotten)" aria-label="Protected profile">
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                    <rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect>
                    <path d="M7 11V7a5 5 0 0 1 10 0v4"></path>
                  </svg>
                </span>
              {/if}
            </div>
          </div>

          <div class="saved-actions">
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              onclick={() => onConnect(item)}
              aria-label="Connect to {item.ssid}"
            >
              Connect
            </button>

            {#if !item.protected}
              {#if confirmingSsid === item.ssid}
                <button
                  type="button"
                  class="btn btn-sm btn-danger"
                  onclick={() => handleForget(item.ssid)}
                  disabled={isForgetting === item.ssid}
                  aria-label="Confirm forgetting {item.ssid}"
                >
                  {#if isForgetting === item.ssid}
                    <span class="spinner" aria-hidden="true"></span>
                  {/if}
                  Confirm forget?
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost cancel-btn"
                  onclick={cancelConfirm}
                  aria-label="Cancel forgetting {item.ssid}"
                >
                  ✕
                </button>
              {:else}
                <button
                  type="button"
                  class="btn btn-sm btn-ghost forget-btn"
                  onclick={() => startForgetConfirm(item.ssid)}
                  disabled={isForgetting === item.ssid}
                  aria-label="Forget network {item.ssid}"
                >
                  Forget
                </button>
              {/if}
            {/if}
          </div>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  .saved-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .header-title-group {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .card-title {
    font-size: var(--font-size-md);
    font-weight: 600;
  }

  .count-badge {
    font-size: var(--font-size-xs);
    background-color: var(--color-raised);
    border: 1px solid var(--color-border);
    padding: 1px 6px;
    border-radius: var(--radius-pill);
    color: var(--color-text-secondary);
  }

  .saved-list {
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 1px;
    background-color: var(--color-border-subtle);
    border: 1px solid var(--color-border-subtle);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  .saved-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    background-color: var(--color-surface);
  }

  .saved-item:hover {
    background-color: var(--color-surface-hover);
  }

  .saved-info {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    min-width: 0;
  }

  .saved-ssid {
    font-size: var(--font-size-sm);
    color: var(--color-text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .saved-badges {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    flex-shrink: 0;
  }

  .protected-indicator {
    display: inline-flex;
    align-items: center;
    color: var(--color-text-muted);
  }

  .saved-actions {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    flex-shrink: 0;
  }

  .forget-btn:hover {
    color: var(--status-error);
  }

  .cancel-btn {
    padding: 0.25rem 0.35rem;
  }

  .empty-state {
    padding: var(--space-4) 0;
    text-align: center;
    color: var(--color-text-muted);
    font-size: var(--font-size-sm);
  }

  .loading-state {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .skeleton-row {
    height: 38px;
    width: 100%;
  }
</style>
