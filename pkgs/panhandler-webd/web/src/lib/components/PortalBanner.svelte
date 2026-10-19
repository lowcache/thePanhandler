<script lang="ts">
  import { PORTAL_PROBE_URL, setPortalBypass, type WifiStatus } from '../api';
  import { toast } from '../toast.svelte';

  let { status }: { status: WifiStatus } = $props();

  let busy = $state(false);
  let left = $state(0);

  const bypass = $derived(status.portalBypass ?? { active: false, secondsLeft: 0 });
  const show = $derived(status.connectivity === 'portal' || bypass.active);

  // Resync the countdown on every status poll; tick locally in between.
  $effect(() => {
    left = bypass.secondsLeft;
    if (!bypass.active) return;
    const t = setInterval(() => (left = Math.max(0, left - 1)), 1000);
    return () => clearInterval(t);
  });

  const mmss = $derived(`${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`);

  async function openPortal() {
    // Open synchronously inside the click so popup blockers allow it, then navigate once DNS is bypassed.
    const tab = window.open('about:blank', '_blank');
    busy = true;
    try {
      await setPortalBypass(true);
      if (tab) {
        tab.opener = null;
        tab.location.href = PORTAL_PROBE_URL;
      } else {
        toast.info(`Popup blocked: open ${PORTAL_PROBE_URL} in a new tab`, 10000);
      }
    } catch (e) {
      tab?.close();
      toast.error(`Portal bypass failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      busy = false;
    }
  }

  async function endBypass() {
    busy = true;
    try {
      await setPortalBypass(false);
      toast.info('Portal bypass ended: DNS back on encrypted upstream');
    } catch (e) {
      toast.error(`Could not end bypass: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      busy = false;
    }
  }
</script>

{#if show}
  <aside class="portal-banner" role="alert" aria-label="Captive portal">
    <div class="banner-inner">
      <div class="banner-icon" aria-hidden="true">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="10"></circle>
          <line x1="12" y1="8" x2="12" y2="12"></line>
          <line x1="12" y1="16" x2="12.01" y2="16"></line>
        </svg>
      </div>
      <div class="banner-content">
        {#if bypass.active}
          <h2 class="banner-heading">Portal bypass active <span class="countdown">{mmss}</span></h2>
          <p class="banner-text">
            Cable DNS is going to the hotel's resolver so its login page can load. Enter your access code in the
            portal tab. The bypass ends by itself once the internet is reachable, or when the timer runs out.
          </p>
        {:else}
          <h2 class="banner-heading">Captive portal detected</h2>
          <p class="banner-text">
            This network wants a login or access code before it routes traffic. Opening the portal briefly sends
            cable DNS to the hotel's resolver (plaintext, up to 10 minutes) so its page can load.
          </p>
        {/if}
      </div>
      <div class="banner-actions">
        {#if bypass.active}
          <button class="btn" onclick={endBypass} disabled={busy}>End bypass</button>
          <a class="btn" href={PORTAL_PROBE_URL} target="_blank" rel="noopener noreferrer">Reopen portal</a>
        {:else}
          <button class="btn btn-primary" onclick={openPortal} disabled={busy}>
            {busy ? 'Opening…' : 'Open portal'}
          </button>
        {/if}
      </div>
    </div>
  </aside>
{/if}

<style>
  .portal-banner {
    background-color: var(--status-portal-bg);
    border-bottom: 1px solid var(--status-portal-border);
    color: var(--color-text-primary);
    padding: var(--space-3) var(--space-4);
  }

  .banner-inner {
    max-width: var(--max-width);
    margin: 0 auto;
    display: flex;
    align-items: flex-start;
    gap: var(--space-3);
  }

  .banner-icon {
    color: var(--status-portal);
    flex-shrink: 0;
    margin-top: 2px;
  }

  .banner-content {
    flex: 1;
  }

  .banner-heading {
    font-size: var(--font-size-sm);
    font-weight: 600;
    color: var(--status-portal);
    margin-bottom: 2px;
  }

  .banner-actions {
    display: flex;
    gap: var(--space-2);
    flex-shrink: 0;
    align-self: center;
  }

  .countdown {
    font-family: var(--font-mono, ui-monospace, monospace);
    margin-left: var(--space-2);
    color: var(--color-text-primary);
  }

  @media (max-width: 640px) {
    .banner-inner {
      flex-wrap: wrap;
    }
    .banner-actions {
      width: 100%;
    }
  }

  .banner-text {
    font-size: var(--font-size-xs);
    color: var(--color-text-secondary);
    line-height: var(--line-height-normal);
  }
</style>
