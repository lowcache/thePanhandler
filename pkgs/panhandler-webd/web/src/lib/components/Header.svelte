<script lang="ts">
</script>

<header class="app-header">
  <div class="header-inner">
    <div class="brand">
      <svg
        class="brand-mark"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <!-- Open hand / tin cup motif -->
        <path d="M5 8h11v7a4 4 0 0 1-4 4H9a4 4 0 0 1-4-4V8z" />
        <path d="M16 10h2.5a2.5 2.5 0 0 1 2.5 2.5v0a2.5 2.5 0 0 1-2.5 2.5H16" />
        <path d="M3 21h18" />
      </svg>
      <span class="brand-title">thePanhandler</span>
    </div>

    <nav class="nav-tabs" aria-label="Main Navigation">
      <button type="button" class="tab-item active" aria-current="page">
        Wi-Fi
      </button>
      <button type="button" class="tab-item disabled" disabled aria-disabled="true">
        <span>Devices</span>
        <span class="phase-tag">Phase B</span>
      </button>
      <button type="button" class="tab-item disabled" disabled aria-disabled="true">
        <span>Logs</span>
        <span class="phase-tag">Phase B</span>
      </button>
    </nav>
  </div>
</header>

<style>
  .app-header {
    background-color: var(--color-surface);
    border-bottom: 1px solid var(--color-border);
    position: sticky;
    top: 0;
    z-index: 100;
  }

  .header-inner {
    max-width: var(--max-width);
    margin: 0 auto;
    padding: 0 var(--space-4);
    height: 56px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-4);
  }

  .brand {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    color: var(--color-text-primary);
  }

  .brand-mark {
    width: 22px;
    height: 22px;
    color: var(--color-accent);
    flex-shrink: 0;
  }

  .brand-title {
    font-size: var(--font-size-base);
    font-weight: 700;
    letter-spacing: -0.02em;
    font-family: var(--font-mono);
  }

  .nav-tabs {
    display: flex;
    align-items: center;
    gap: var(--space-1);
    height: 100%;
  }

  .tab-item {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    height: 56px;
    padding: 0 var(--space-3);
    background: transparent;
    border: none;
    border-bottom: 2px solid transparent;
    color: var(--color-text-secondary);
    font-family: var(--font-sans);
    font-size: var(--font-size-sm);
    font-weight: 500;
    cursor: pointer;
    text-decoration: none;
    transition: color 0.15s ease, border-color 0.15s ease;
  }

  .tab-item.active {
    color: var(--color-text-primary);
    border-bottom-color: var(--color-accent);
  }

  .tab-item.disabled {
    cursor: not-allowed;
    opacity: 0.55;
  }

  .phase-tag {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    background-color: var(--color-raised);
    border: 1px solid var(--color-border);
    color: var(--color-text-muted);
    padding: 1px 4px;
    border-radius: var(--radius-sm);
    line-height: 1.2;
  }
</style>
