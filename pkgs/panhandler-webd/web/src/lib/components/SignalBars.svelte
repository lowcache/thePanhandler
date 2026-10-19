<script lang="ts">
  let { signal = 0, showPercent = false, size = 'md' }: {
    signal: number;
    showPercent?: boolean;
    size?: 'sm' | 'md';
  } = $props();

  const clampedSignal = $derived(Math.max(0, Math.min(100, Math.round(signal))));

  const bars = $derived([
    clampedSignal > 0,
    clampedSignal >= 30,
    clampedSignal >= 60,
    clampedSignal >= 80,
  ]);
</script>

<div class="signal-indicator {size}" role="img" aria-label="{clampedSignal}% signal strength">
  <div class="bars" aria-hidden="true">
    {#each bars as active, idx}
      <span class="bar bar-{idx + 1}" class:active></span>
    {/each}
  </div>
  {#if showPercent}
    <span class="percent font-mono">{clampedSignal}%</span>
  {/if}
</div>

<style>
  .signal-indicator {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    vertical-align: middle;
  }

  .bars {
    display: flex;
    align-items: flex-end;
    gap: 2px;
    height: 14px;
    width: 14px;
  }

  .signal-indicator.sm .bars {
    height: 12px;
    width: 12px;
    gap: 1.5px;
  }

  .bar {
    flex: 1;
    background-color: var(--color-border);
    border-radius: 1px;
    transition: background-color 0.2s ease;
  }

  .bar-1 { height: 25%; }
  .bar-2 { height: 50%; }
  .bar-3 { height: 75%; }
  .bar-4 { height: 100%; }

  .bar.active {
    background-color: var(--color-accent);
  }

  .percent {
    font-size: var(--font-size-xs);
    color: var(--color-text-secondary);
  }
</style>
