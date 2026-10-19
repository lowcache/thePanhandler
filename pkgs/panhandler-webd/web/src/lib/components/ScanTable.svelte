<script lang="ts">
  import {
    formatSecurity,
    frequencyToBand,
    type ScanNetwork
  } from '../api';
  import SignalBars from './SignalBars.svelte';

  let {
    networks = [],
    isLoading = false,
    isRefreshing = false,
    hasLoadedInitial = false,
    onSelectNetwork,
    onRefresh
  }: {
    networks: ScanNetwork[];
    isLoading?: boolean;
    isRefreshing?: boolean;
    hasLoadedInitial?: boolean;
    onSelectNetwork: (network: ScanNetwork) => void;
    onRefresh: () => void;
  } = $props();

  function handleRowKeyDown(e: KeyboardEvent, network: ScanNetwork) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onSelectNetwork(network);
    }
  }
</script>

<div class="card scan-card">
  <div class="scan-header">
    <div class="header-left">
      <h2 class="card-title">Available Wi-Fi Networks</h2>
      {#if hasLoadedInitial}
        <span class="count-badge font-mono">{networks.length}</span>
      {/if}
    </div>

    <button
      type="button"
      class="btn btn-sm btn-ghost refresh-btn"
      onclick={onRefresh}
      disabled={isRefreshing || isLoading}
      aria-label="Refresh Wi-Fi scan"
    >
      {#if isRefreshing}
        <span class="spinner" aria-hidden="true"></span>
        <span>Scanning...</span>
      {:else}
        <svg class="refresh-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <polyline points="23 4 23 10 17 10"></polyline>
          <polyline points="1 20 1 14 7 14"></polyline>
          <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path>
        </svg>
        <span>Refresh</span>
      {/if}
    </button>
  </div>

  {#if !hasLoadedInitial}
    <!-- Skeleton loader before first scan returns -->
    <div class="skeleton-table" aria-label="Loading available networks" aria-busy="true">
      <div class="skeleton-row skeleton"></div>
      <div class="skeleton-row skeleton"></div>
      <div class="skeleton-row skeleton"></div>
      <div class="skeleton-row skeleton"></div>
      <div class="skeleton-row skeleton"></div>
    </div>
  {:else if networks.length === 0}
    <div class="empty-state">
      <p>No Wi-Fi networks discovered in range.</p>
      <button type="button" class="btn btn-sm" onclick={onRefresh} disabled={isRefreshing}>
        Scan Again
      </button>
    </div>
  {:else}
    <div class="table-container">
      <table class="scan-table">
        <thead>
          <tr>
            <th scope="col" class="th-ssid">SSID</th>
            <th scope="col" class="th-signal">Signal</th>
            <th scope="col" class="th-band">Band</th>
            <th scope="col" class="th-security">Security</th>
            <th scope="col" class="th-status">Status</th>
            <th scope="col" class="th-action text-right">Action</th>
          </tr>
        </thead>
        <tbody>
          {#each networks as net (net.bssid || net.ssid)}
            <tr
              class="scan-row"
              class:row-active={net.inUse}
              tabindex="0"
              role="button"
              onclick={() => onSelectNetwork(net)}
              onkeydown={(e) => handleRowKeyDown(e, net)}
              aria-label="Connect to {net.ssid || 'Hidden Network'}"
            >
              <td class="td-ssid" data-label="SSID">
                <div class="ssid-wrapper">
                  {#if net.ssid}
                    <span class="ssid-text font-mono">{net.ssid}</span>
                  {:else}
                    <span class="ssid-hidden text-muted font-mono">&lt;hidden network&gt;</span>
                  {/if}
                  <span class="bssid-sub font-mono">{net.bssid}</span>
                </div>
              </td>

              <td class="td-signal" data-label="Signal">
                <SignalBars signal={net.signal} showPercent={true} size="sm" />
              </td>

              <td class="td-band font-mono" data-label="Band">
                {frequencyToBand(net.frequency)}
              </td>

              <td class="td-security" data-label="Security">
                <span class="badge badge-security">
                  {formatSecurity(net.security)}
                </span>
              </td>

              <td class="td-status" data-label="Status">
                <div class="status-tags">
                  {#if net.inUse}
                    <span class="pill pill-full pill-compact">Connected</span>
                  {/if}
                  {#if net.saved}
                    <span class="badge badge-saved">Saved</span>
                  {/if}
                </div>
              </td>

              <td class="td-action text-right" data-label="Action">
                <button
                  type="button"
                  class="btn btn-sm {net.inUse ? 'btn-ghost' : 'btn-primary'} connect-row-btn"
                  onclick={(e) => {
                    e.stopPropagation();
                    onSelectNetwork(net);
                  }}
                >
                  {net.inUse ? 'Active' : 'Connect'}
                </button>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>

<style>
  .scan-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .scan-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
  }

  .header-left {
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

  .refresh-btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
  }

  .refresh-icon {
    flex-shrink: 0;
  }

  .table-container {
    width: 100%;
    overflow-x: auto;
  }

  .scan-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--font-size-sm);
    text-align: left;
  }

  .scan-table thead tr {
    border-bottom: 1px solid var(--color-border);
  }

  .scan-table th {
    font-size: var(--font-size-xs);
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-text-muted);
    padding: var(--space-2) var(--space-3);
  }

  .scan-row {
    border-bottom: 1px solid var(--color-border-subtle);
    cursor: pointer;
    transition: background-color 0.15s ease;
  }

  .scan-row:hover {
    background-color: var(--color-surface-hover);
  }

  .scan-row:focus-visible {
    outline: 2px solid var(--color-accent);
    outline-offset: -2px;
  }

  .row-active {
    background-color: rgba(63, 185, 80, 0.05);
  }

  .scan-table td {
    padding: var(--space-2) var(--space-3);
    vertical-align: middle;
  }

  .text-right {
    text-align: right;
  }

  .ssid-wrapper {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .ssid-text {
    font-weight: 500;
    color: var(--color-text-primary);
  }

  .bssid-sub {
    font-size: var(--font-size-xs);
    color: var(--color-text-muted);
  }

  .badge-saved {
    background-color: var(--color-raised);
    border-color: var(--color-border);
    color: var(--color-accent);
  }

  .status-tags {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    flex-wrap: wrap;
  }

  .pill-compact {
    padding: 0.1rem 0.4rem;
    font-size: 0.625rem;
  }

  .skeleton-table {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-2) 0;
  }

  .skeleton-row {
    height: 44px;
    width: 100%;
  }

  .empty-state {
    padding: var(--space-6) 0;
    text-align: center;
    color: var(--color-text-muted);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-3);
  }

  /* Responsive layout for mobile (<640px) */
  @media (max-width: 640px) {
    .scan-table,
    .scan-table thead,
    .scan-table tbody,
    .scan-table th,
    .scan-table td,
    .scan-table tr {
      display: block;
    }

    .scan-table thead {
      display: none;
    }

    .scan-row {
      border: 1px solid var(--color-border);
      border-radius: var(--radius-md);
      margin-bottom: var(--space-2);
      padding: var(--space-3);
      background-color: var(--color-surface);
    }

    .scan-table td {
      padding: var(--space-1) 0;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }

    .scan-table td::before {
      content: attr(data-label);
      font-size: var(--font-size-xs);
      font-weight: 600;
      color: var(--color-text-muted);
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    .scan-table td.td-ssid {
      padding-bottom: var(--space-2);
      margin-bottom: var(--space-1);
      border-bottom: 1px solid var(--color-border-subtle);
      display: block;
    }

    .scan-table td.td-ssid::before {
      display: none;
    }

    .scan-table td.td-action {
      padding-top: var(--space-2);
      margin-top: var(--space-1);
      border-top: 1px solid var(--color-border-subtle);
      justify-content: flex-end;
    }

    .scan-table td.td-action::before {
      display: none;
    }

    .connect-row-btn {
      width: 100%;
    }
  }
</style>
