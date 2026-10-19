<script lang="ts">
  import { connectWifi, formatSecurity, type ScanNetwork } from '../api';

  let {
    network = null,
    isOpen = false,
    onClose,
    onConnectSuccess
  }: {
    network: ScanNetwork | null;
    isOpen: boolean;
    onClose: () => void;
    onConnectSuccess: (ssid: string, ip: string) => void;
  } = $props();

  let dialogRef = $state<HTMLDialogElement | null>(null);
  let passphrase = $state('');
  let showPassword = $state(false);
  let isConnecting = $state(false);
  let errorMessage = $state<string | null>(null);

  const isSaved = $derived(network?.saved ?? false);
  const isSecurityUnsupported = $derived(
    network?.security === 'enterprise' || network?.security === 'wep'
  );
  const isOpenSecurity = $derived(
    network?.security === 'open' || network?.security === 'owe'
  );

  const isPassphraseValid = $derived.by(() => {
    if (!network) return false;
    if (isOpenSecurity) return true;
    if (isSecurityUnsupported) return false;
    if (isSaved && passphrase.length === 0) return true;
    // 8-63 printable ASCII (32-126)
    if (/^[\x20-\x7e]{8,63}$/.test(passphrase)) return true;
    // or exactly 64 hex characters
    if (/^[0-9a-fA-F]{64}$/.test(passphrase)) return true;
    return false;
  });

  const showValidationWarning = $derived(
    !isOpenSecurity &&
    !isSecurityUnsupported &&
    passphrase.length > 0 &&
    !isPassphraseValid
  );

  $effect(() => {
    if (isOpen && dialogRef && !dialogRef.open) {
      passphrase = '';
      showPassword = false;
      errorMessage = null;
      isConnecting = false;
      dialogRef.showModal();
    } else if (!isOpen && dialogRef && dialogRef.open) {
      passphrase = '';
      errorMessage = null;
      dialogRef.close();
    }
  });

  function handleDialogClose() {
    passphrase = '';
    errorMessage = null;
    isConnecting = false;
    onClose();
  }

  function handleBackdropClick(e: MouseEvent) {
    if (e.target === dialogRef && !isConnecting) {
      dialogRef?.close();
    }
  }

  async function handleSubmit(e: SubmitEvent) {
    e.preventDefault();
    if (!network || !isPassphraseValid || isConnecting) return;

    errorMessage = null;
    isConnecting = true;

    try {
      const res = await connectWifi(
        network.ssid,
        passphrase.length > 0 ? passphrase : undefined
      );
      passphrase = '';
      onConnectSuccess(res.ssid, res.ip);
      dialogRef?.close();
    } catch (err: unknown) {
      if (err instanceof Error) {
        errorMessage = err.message;
      } else {
        errorMessage = 'Failed to connect to network';
      }
    } finally {
      isConnecting = false;
    }
  }
</script>

<dialog
  bind:this={dialogRef}
  class="join-dialog"
  onclose={handleDialogClose}
  onclick={handleBackdropClick}
  aria-labelledby="dialog-title"
>
  <div class="dialog-content">
    <div class="dialog-header">
      <h2 id="dialog-title" class="dialog-title">
        Connect to {network?.ssid || 'Network'}
      </h2>
      <button
        type="button"
        class="dialog-close-btn"
        onclick={() => dialogRef?.close()}
        disabled={isConnecting}
        aria-label="Close dialog"
      >
        ✕
      </button>
    </div>

    {#if network}
      <div class="network-meta">
        <span class="badge badge-security">
          {formatSecurity(network.security)}
        </span>
        <span class="meta-bssid font-mono">{network.bssid}</span>
        {#if network.saved}
          <span class="badge badge-saved">Saved profile</span>
        {/if}
      </div>

      {#if isSecurityUnsupported}
        <div class="dialog-alert alert-warning" role="alert">
          <p>
            <strong>{formatSecurity(network.security)}</strong> networks are not supported in this phase.
          </p>
        </div>
        <div class="dialog-actions">
          <button
            type="button"
            class="btn"
            onclick={() => dialogRef?.close()}
          >
            Close
          </button>
        </div>
      {:else}
        <form onsubmit={handleSubmit} class="join-form">
          {#if isOpenSecurity}
            <p class="open-notice">
              This is an unencrypted network. No passphrase is required to connect.
            </p>
          {:else}
            <div class="form-group">
              <label for="wifi-passphrase" class="input-label">
                Passphrase
                {#if isSaved}
                  <span class="label-hint">(leave blank to use saved password)</span>
                {/if}
              </label>

              <div class="password-input-group">
                <input
                  id="wifi-passphrase"
                  type={showPassword ? 'text' : 'password'}
                  class="input-text font-mono"
                  placeholder={isSaved ? '•••••••• (using saved)' : '8-63 ASCII or 64 hex'}
                  autocomplete="off"
                  disabled={isConnecting}
                  bind:value={passphrase}
                  required={!isSaved}
                />
                <button
                  type="button"
                  class="btn btn-ghost toggle-password-btn"
                  onclick={() => (showPassword = !showPassword)}
                  disabled={isConnecting}
                  aria-label={showPassword ? 'Hide passphrase' : 'Show passphrase'}
                >
                  {#if showPassword}
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"></path>
                      <line x1="1" y1="1" x2="23" y2="23"></line>
                    </svg>
                  {:else}
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path>
                      <circle cx="12" cy="12" r="3"></circle>
                    </svg>
                  {/if}
                </button>
              </div>

              {#if showValidationWarning}
                <p class="field-error" role="alert">
                  Passphrase must be 8-63 printable ASCII characters or exactly 64 hexadecimal characters.
                </p>
              {/if}
            </div>
          {/if}

          {#if errorMessage}
            <div class="dialog-alert alert-error font-mono" role="alert">
              <strong>Error:</strong> {errorMessage}
            </div>
          {/if}

          {#if isConnecting}
            <div class="connecting-progress" role="status" aria-live="polite">
              <span class="spinner" aria-hidden="true"></span>
              <span>Associating... this can take up to 45s</span>
            </div>
          {/if}

          <div class="dialog-actions">
            <button
              type="button"
              class="btn btn-ghost"
              onclick={() => dialogRef?.close()}
              disabled={isConnecting}
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary"
              disabled={isConnecting || !isPassphraseValid}
            >
              {#if isConnecting}
                <span class="spinner" aria-hidden="true"></span>
                <span>Connecting...</span>
              {:else}
                <span>Connect</span>
              {/if}
            </button>
          </div>
        </form>
      {/if}
    {/if}
  </div>
</dialog>

<style>
  .join-dialog {
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    background-color: var(--color-surface);
    color: var(--color-text-primary);
    padding: 0;
  }

  .dialog-content {
    padding: var(--space-5);
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .dialog-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-2);
  }

  .dialog-title {
    font-size: var(--font-size-md);
    font-weight: 600;
  }

  .dialog-close-btn {
    background: transparent;
    border: none;
    color: var(--color-text-muted);
    cursor: pointer;
    font-size: var(--font-size-md);
    padding: var(--space-1);
    line-height: 1;
    border-radius: var(--radius-sm);
  }

  .dialog-close-btn:hover:not(:disabled) {
    color: var(--color-text-primary);
  }

  .network-meta {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--font-size-xs);
  }

  .meta-bssid {
    color: var(--color-text-muted);
  }

  .badge-saved {
    background-color: var(--color-raised);
    color: var(--color-accent);
    border-color: var(--color-border);
  }

  .join-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  .open-notice {
    font-size: var(--font-size-sm);
    color: var(--color-text-secondary);
  }

  .form-group {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .input-label {
    font-size: var(--font-size-xs);
    font-weight: 600;
    color: var(--color-text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .label-hint {
    text-transform: none;
    font-weight: 400;
    color: var(--color-text-muted);
  }

  .password-input-group {
    position: relative;
    display: flex;
    align-items: center;
  }

  .password-input-group .input-text {
    padding-right: 2.5rem;
  }

  .toggle-password-btn {
    position: absolute;
    right: 4px;
    padding: 6px;
    border-radius: var(--radius-sm);
  }

  .field-error {
    font-size: var(--font-size-xs);
    color: var(--status-error);
  }

  .dialog-alert {
    padding: var(--space-3);
    border-radius: var(--radius-md);
    font-size: var(--font-size-xs);
    line-height: var(--line-height-normal);
  }

  .alert-warning {
    background-color: var(--status-limited-bg);
    border: 1px solid var(--status-limited-border);
    color: var(--status-limited);
  }

  .alert-error {
    background-color: var(--status-error-bg);
    border: 1px solid var(--status-error-border);
    color: var(--status-error);
    word-break: break-all;
  }

  .connecting-progress {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    font-size: var(--font-size-xs);
    color: var(--color-accent);
    background-color: var(--color-accent-subtle);
    padding: var(--space-2) var(--space-3);
    border-radius: var(--radius-md);
    border: 1px solid var(--color-accent-border);
  }

  .dialog-actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-2);
    margin-top: var(--space-2);
  }
</style>
