<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchEgressMode, setEgressMode, type EgressMode } from '../api';

  let mode = $state<EgressMode | null>(null);
  let busy = $state(false);
  let error = $state('');
  let loading = $state(true);
  let canUseDirect = $state(false);
  let revision = 0;

  async function refresh() {
    const current = ++revision;
    try {
      const state = await fetchEgressMode();
      if (current !== revision) return;
      mode = state.mode;
      canUseDirect = state.canUseDirect;
      error = '';
    } catch {
      if (current !== revision) return;
      mode = null;
      error = 'Cannot read the active mode. Refresh before browsing.';
    } finally {
      loading = false;
    }
  }

  async function change(next: EgressMode) {
    ++revision;
    busy = true;
    error = '';
    try {
      const state = await setEgressMode(next);
      mode = state.mode;
      canUseDirect = state.canUseDirect;
    } catch (e) {
      mode = null;
      error = e instanceof Error ? e.message : 'Mode switch failed. Refresh before browsing.';
    } finally {
      busy = false;
    }
  }

  onMount(() => {
    refresh();
    const timer = setInterval(() => { if (!busy) refresh(); }, 5000);
    return () => clearInterval(timer);
  });
</script>

<section class="egress" aria-labelledby="egress-heading" aria-busy={busy}>
  <div aria-live="polite">
    <h2 id="egress-heading">Internet mode: {mode === 'tor' ? 'Tor' : mode === 'direct' ? 'Direct' : loading ? 'Loading…' : 'Unknown'}</h2>
    {#if mode === 'direct'}
      <p>Traffic leaves through the hotel network. Tor privacy is off; streaming and other protocols work normally.</p>
    {:else if mode === 'tor'}
      <p>TCP and DNS use Tor. Other traffic is blocked. If Tor is unavailable or storage is locked, access stays blocked. Portal access temporarily permits direct web traffic.</p>
    {/if}
  </div>
  <div class="actions" aria-label="Choose internet mode">
    <button class="btn" disabled={busy || loading || !canUseDirect || mode === 'direct'} onclick={() => change('direct')}>Use Direct</button>
    <button class="btn" disabled={busy || loading || mode === 'tor'} onclick={() => change('tor')}>Use Tor</button>
    <button class="btn" disabled={busy} onclick={refresh}>Refresh mode</button>
  </div>
  {#if !loading && !canUseDirect}<p>To use Direct, open this UI over Tailscale from the laptop or phone. Cable SSH recovery: <code>sudo ph-egress direct</code>.</p>{/if}
  {#if busy}<p role="status">Applying mode; existing connections may close…</p>{/if}
  {#if error}<p role="alert">{error}</p>{/if}
</section>

<style>
  .egress { display: flex; flex-direction: column; gap: var(--space-3); }
  h2 { font-size: var(--font-size-lg); }
  p { max-width: 70ch; }
  .actions { display: flex; flex-wrap: wrap; gap: var(--space-2); }
</style>
