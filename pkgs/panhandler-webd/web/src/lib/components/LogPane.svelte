<script lang="ts">
  import { onDestroy, tick } from 'svelte';
  import { LOGS_URL, type LogEntry } from '../api';

  const MAX_LINES = 500;

  let lines = $state<(LogEntry & { id: number })[]>([]);
  let source: EventSource | null = null;
  let running = $state(false);
  let status = $state('');
  let follow = $state(true);
  let hidden = $state<Set<string>>(new Set());
  let pane: HTMLDivElement | undefined = $state();
  let nextId = 0;

  let units = $derived([...new Set(lines.map((l) => l.unit))].sort());
  let shown = $derived(lines.filter((l) => !hidden.has(l.unit)));

  // Off until asked for: each stream is a journalctl on the Pi, and the Pi allows three.
  function start() {
    stop();
    status = 'connecting';
    source = new EventSource(LOGS_URL);
    running = true;
    source.onopen = () => (status = 'live');
    source.addEventListener('log', async (ev) => {
      const e = JSON.parse((ev as MessageEvent).data) as LogEntry;
      lines.push({ ...e, id: nextId++ });
      if (lines.length > MAX_LINES) lines.splice(0, lines.length - MAX_LINES);
      if (follow && pane) {
        await tick();
        pane.scrollTop = pane.scrollHeight;
      }
    });
    source.onerror = () => {
      if (source?.readyState === EventSource.CLOSED) {
        // A refused stream (403/503) closes for good; a dropped one reconnects on its own.
        status = 'unavailable: logs need the cable or an approved device, and at most 3 viewers';
        running = false;
      } else {
        status = 'reconnecting';
      }
    };
  }

  function stop() {
    source?.close();
    source = null;
    running = false;
    status = '';
  }

  function toggleUnit(u: string) {
    const next = new Set(hidden);
    if (next.has(u)) next.delete(u);
    else next.add(u);
    hidden = next;
  }

  function onScroll() {
    if (!pane) return;
    follow = pane.scrollHeight - pane.scrollTop - pane.clientHeight < 24;
  }

  function time(iso: string): string {
    return iso ? iso.slice(11, 19) : '';
  }

  onDestroy(stop);
</script>

<div class="card log-card">
  <div class="card-header">
    <div class="header-left">
      <h2 class="card-title">Live logs</h2>
      {#if status}
        <span class="status font-mono" class:live={status === 'live'}>{status}</span>
      {/if}
    </div>
    <div class="actions">
      {#if lines.length}
        <button type="button" class="btn btn-sm btn-ghost" onclick={() => (lines = [])}>Clear</button>
      {/if}
      <button type="button" class="btn btn-sm" onclick={running ? stop : start}>
        {running ? 'Stop' : 'Start'}
      </button>
    </div>
  </div>

  {#if units.length}
    <div class="pills">
      {#each units as u (u)}
        <button
          type="button"
          class="unit-pill font-mono"
          class:off={hidden.has(u)}
          aria-pressed={!hidden.has(u)}
          onclick={() => toggleUnit(u)}>{u}</button
        >
      {/each}
      {#if !follow}
        <button type="button" class="unit-pill font-mono" onclick={() => {
          follow = true;
          if (pane) pane.scrollTop = pane.scrollHeight;
        }}>↓ follow</button>
      {/if}
    </div>
  {/if}

  {#if running || lines.length}
    <div class="pane font-mono" bind:this={pane} onscroll={onScroll} role="log" aria-live="off">
      {#each shown as l (l.id)}
        <div class="line prio-{l.priority}">
          <span class="ts">{time(l.timestamp)}</span>
          <span class="unit">{l.unit}</span>
          <span class="msg">{l.message}</span>
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .log-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: var(--space-2);
    flex-wrap: wrap;
  }

  .header-left,
  .actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .card-title {
    font-size: var(--font-size-md);
    font-weight: 600;
  }

  .status {
    font-size: var(--font-size-xs);
    color: var(--status-portal);
  }

  .status.live {
    color: var(--status-full);
  }

  .pills {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-1);
  }

  .unit-pill {
    font-size: var(--font-size-xs);
    padding: 0.1rem 0.5rem;
    border-radius: var(--radius-pill);
    border: 1px solid var(--color-accent-border);
    background-color: var(--color-accent-subtle);
    color: var(--color-accent);
    cursor: pointer;
  }

  .unit-pill.off {
    border-color: var(--color-border);
    background-color: transparent;
    color: var(--color-text-muted);
  }

  .pane {
    height: 22rem;
    overflow-y: auto;
    background-color: var(--color-bg);
    border: 1px solid var(--color-border-subtle);
    border-radius: var(--radius-md);
    padding: var(--space-2);
    font-size: var(--font-size-xs);
    line-height: var(--line-height-normal);
  }

  .line {
    display: flex;
    gap: var(--space-2);
    white-space: pre-wrap;
    word-break: break-word;
  }

  .ts {
    color: var(--color-text-muted);
    flex-shrink: 0;
  }

  .unit {
    color: var(--color-text-secondary);
    flex-shrink: 0;
    min-width: 7rem;
  }

  .msg {
    color: var(--color-text-primary);
  }

  .prio-warning .msg,
  .prio-notice .msg {
    color: var(--status-portal);
  }

  .prio-err .msg,
  .prio-crit .msg,
  .prio-alert .msg,
  .prio-emerg .msg {
    color: var(--status-error);
  }

  .prio-debug .msg {
    color: var(--color-text-muted);
  }

  @media (max-width: 640px) {
    .unit {
      min-width: 0;
    }

    .line {
      flex-wrap: wrap;
    }
  }
</style>
