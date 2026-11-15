<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchDevices, type Device } from '../api';

  let devices = $state<Device[]>([]);
  let loaded = $state(false);
  let busy = $state(false);
  let error = $state('');

  async function load() {
    busy = true;
    try {
      devices = await fetchDevices();
      error = '';
    } catch (err: unknown) {
      error = err instanceof Error ? err.message : 'Failed to load devices';
    } finally {
      busy = false;
      loaded = true;
    }
  }

  function expiry(iso: string): string {
    if (!iso) return 'static';
    const mins = Math.round((Date.parse(iso) - Date.now()) / 60000);
    if (mins <= 0) return 'expired';
    return mins < 60 ? `${mins} min` : `${Math.floor(mins / 60)} h ${mins % 60} min`;
  }

  onMount(() => {
    load();
    const t = setInterval(load, 30000);
    return () => clearInterval(t);
  });
</script>

<div class="card devices-card">
  <div class="card-header">
    <div class="header-left">
      <h2 class="card-title">Devices on the cable</h2>
      {#if loaded}
        <span class="count-badge font-mono">{devices.length}</span>
      {/if}
    </div>
    <button type="button" class="btn btn-sm btn-ghost" onclick={load} disabled={busy}>
      {busy ? 'Loading...' : 'Refresh'}
    </button>
  </div>

  {#if error}
    <p class="note error">{error}</p>
  {:else if loaded && devices.length === 0}
    <p class="note">No devices on the cable.</p>
  {:else if loaded}
    <div class="table-container">
      <table class="device-table">
        <thead>
          <tr>
            <th scope="col">Device</th>
            <th scope="col">IP</th>
            <th scope="col">MAC</th>
            <th scope="col">Vendor</th>
            <th scope="col">Lease</th>
          </tr>
        </thead>
        <tbody>
          {#each devices as d (d.mac)}
            <tr class:offline={!d.online}>
              <td data-label="Device">
                <span class="dot" class:on={d.online} aria-label={d.online ? 'online' : 'offline'}></span>
                {d.hostname || '—'}
              </td>
              <td data-label="IP" class="font-mono">{d.ip}</td>
              <td data-label="MAC" class="font-mono">{d.mac}</td>
              <td data-label="Vendor" class:muted={d.vendor === 'randomized' || !d.vendor}>
                {d.vendor || 'unknown'}
              </td>
              <td data-label="Lease" class="font-mono">{expiry(d.leaseExpires)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>

<style>
  .devices-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
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
    border-radius: var(--radius-pill);
    padding: 0 var(--space-2);
    color: var(--color-text-secondary);
  }

  .note {
    color: var(--color-text-muted);
    font-size: var(--font-size-sm);
  }

  .note.error {
    color: var(--status-error);
  }

  .table-container {
    width: 100%;
    overflow-x: auto;
  }

  .device-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--font-size-sm);
    text-align: left;
  }

  .device-table thead tr {
    border-bottom: 1px solid var(--color-border);
  }

  .device-table th {
    font-size: var(--font-size-xs);
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-text-muted);
    padding: var(--space-2) var(--space-3);
  }

  .device-table td {
    padding: var(--space-2) var(--space-3);
    border-bottom: 1px solid var(--color-border-subtle);
  }

  .offline td {
    color: var(--color-text-muted);
  }

  .muted {
    color: var(--color-text-muted);
  }

  .dot {
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    margin-right: var(--space-2);
    background-color: var(--status-none);
  }

  .dot.on {
    background-color: var(--status-full);
  }

  @media (max-width: 640px) {
    .device-table,
    .device-table tbody,
    .device-table tr,
    .device-table td {
      display: block;
    }

    .device-table thead {
      display: none;
    }

    .device-table tr {
      border: 1px solid var(--color-border);
      border-radius: var(--radius-md);
      margin-bottom: var(--space-2);
      padding: var(--space-2) var(--space-3);
    }

    .device-table td {
      display: flex;
      justify-content: space-between;
      padding: var(--space-1) 0;
      border-bottom: none;
    }

    .device-table td::before {
      content: attr(data-label);
      font-size: var(--font-size-xs);
      font-weight: 600;
      color: var(--color-text-muted);
      text-transform: uppercase;
    }
  }
</style>
