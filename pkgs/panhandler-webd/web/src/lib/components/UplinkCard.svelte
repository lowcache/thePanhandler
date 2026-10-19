<script lang="ts">
  import { fetchWifiStatus, frequencyToBand, type WifiStatus } from '../api';
  import SignalBars from './SignalBars.svelte';

  let {
    status = null,
    onStatusChange
  }: {
    status?: WifiStatus | null;
    onStatusChange?: (newStatus: WifiStatus) => void;
  } = $props();

  let localStatus = $state<WifiStatus | null>(null);
  let isPolling = $state(false);

  // Sync with prop when prop changes
  $effect(() => {
    if (status !== null) {
      localStatus = status;
    }
  });

  async function pollStatus() {
    if (typeof document !== 'undefined' && document.hidden) {
      return;
    }
    try {
      isPolling = true;
      const data = await fetchWifiStatus();
      localStatus = data;
      onStatusChange?.(data);
    } catch {
      // Retain existing state on transient poll failure
    } finally {
      isPolling = false;
    }
  }

  $effect(() => {
    // Initial fetch
    pollStatus();

    const interval = setInterval(pollStatus, 5000);

    function handleVisibilityChange() {
      if (!document.hidden) {
        pollStatus();
      }
    }

    document.addEventListener('visibilitychange', handleVisibilityChange);

    return () => {
      clearInterval(interval);
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  });

  const connectivity = $derived(localStatus?.connectivity ?? 'unknown');
  const isConnected = $derived(localStatus?.connected ?? false);
  const persistState = $derived(localStatus?.persist ?? 'unlocked');
</script>

<div class="card uplink-card">
  <div class="card-header">
    <div class="header-title-group">
      <h2 class="card-title">Uplink Status</h2>
      {#if isPolling}
        <span class="poll-indicator" aria-label="Polling status"></span>
      {/if}
    </div>

    <div class="pill pill-{connectivity}" role="status" aria-label="Connectivity state: {connectivity}">
      <span class="pill-dot"></span>
      <span>{connectivity}</span>
    </div>
  </div>

  {#if !localStatus}
    <div class="loading-state">
      <div class="skeleton-line skeleton"></div>
      <div class="skeleton-line skeleton"></div>
      <div class="skeleton-line skeleton"></div>
    </div>
  {:else}
    <div class="grid-details">
      <div class="detail-item">
        <span class="detail-label">Network (SSID)</span>
        <span class="detail-value font-mono">
          {#if isConnected && localStatus.uplinkSsid}
            {localStatus.uplinkSsid}
          {:else}
            <span class="text-muted">Not connected</span>
          {/if}
        </span>
      </div>

      <div class="detail-item">
        <span class="detail-label">State</span>
        <span class="detail-value font-mono capitalize">
          {localStatus.state}
        </span>
      </div>

      <div class="detail-item">
        <span class="detail-label">IP Address</span>
        <span class="detail-value font-mono">
          {localStatus.ip || '—'}
        </span>
      </div>

      <div class="detail-item">
        <span class="detail-label">BSSID</span>
        <span class="detail-value font-mono">
          {localStatus.bssid || '—'}
        </span>
      </div>

      <div class="detail-item">
        <span class="detail-label">Band</span>
        <span class="detail-value font-mono">
          {frequencyToBand(localStatus.frequency)}
        </span>
      </div>

      <div class="detail-item">
        <span class="detail-label">Signal</span>
        <div class="detail-value">
          {#if isConnected}
            <SignalBars signal={localStatus.signal} showPercent={true} />
          {:else}
            <span class="text-muted">—</span>
          {/if}
        </div>
      </div>
    </div>

    {#if persistState === 'locked'}
      <div class="persist-notice" role="note">
        <svg class="persist-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect>
          <path d="M7 11V7a5 5 0 0 1 10 0v4"></path>
        </svg>
        <span>
          Storage is locked. New Wi-Fi networks are held in temporary memory and lost on reboot unless /persist is unlocked.
        </span>
      </div>
    {/if}
  {/if}
</div>

<style>
  .uplink-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
  }

  .header-title-group {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .card-title {
    font-size: var(--font-size-md);
    font-weight: 600;
    color: var(--color-text-primary);
  }

  .poll-indicator {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background-color: var(--color-accent);
    opacity: 0.8;
  }

  .grid-details {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(130px, 1fr));
    gap: var(--space-3) var(--space-4);
  }

  .detail-item {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .detail-label {
    font-size: var(--font-size-xs);
    color: var(--color-text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .detail-value {
    font-size: var(--font-size-sm);
    color: var(--color-text-primary);
    word-break: break-all;
  }

  .capitalize {
    text-transform: capitalize;
  }

  .text-muted {
    color: var(--color-text-muted);
  }

  .persist-notice {
    display: flex;
    align-items: flex-start;
    gap: var(--space-2);
    font-size: var(--font-size-xs);
    color: var(--color-accent);
    background-color: var(--color-accent-subtle);
    border: 1px solid var(--color-accent-border);
    border-radius: var(--radius-md);
    padding: var(--space-2) var(--space-3);
    line-height: var(--line-height-normal);
  }

  .persist-icon {
    flex-shrink: 0;
    margin-top: 2px;
  }

  .loading-state {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-2) 0;
  }

  .skeleton-line {
    height: 18px;
    width: 100%;
  }

  .skeleton-line:nth-child(2) {
    width: 70%;
  }

  .skeleton-line:nth-child(3) {
    width: 85%;
  }
</style>
