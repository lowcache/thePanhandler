<script lang="ts">
  import { onMount } from 'svelte';
  import {
    connectWifi,
    fetchSavedNetworks,
    fetchWifiScan,
    fetchWifiStatus,
    forgetWifi,
    type SavedNetwork,
    type ScanNetwork,
    type WifiStatus,
  } from './lib/api';
  import Header from './lib/components/Header.svelte';
  import JoinDialog from './lib/components/JoinDialog.svelte';
  import PortalBanner from './lib/components/PortalBanner.svelte';
  import SavedList from './lib/components/SavedList.svelte';
  import ScanTable from './lib/components/ScanTable.svelte';
  import Toasts from './lib/components/Toasts.svelte';
  import UplinkCard from './lib/components/UplinkCard.svelte';
  import { toast } from './lib/toast.svelte';

  let wifiStatus = $state<WifiStatus | null>(null);
  let scanNetworks = $state<ScanNetwork[]>([]);
  let savedNetworks = $state<SavedNetwork[]>([]);

  let isScanLoading = $state(true);
  let isScanRefreshing = $state(false);
  let hasLoadedInitialScan = $state(false);
  let isSavedLoading = $state(true);

  let selectedNetworkForJoin = $state<ScanNetwork | null>(null);
  let isJoinDialogOpen = $state(false);

  async function loadScan(refresh = false) {
    if (refresh) {
      isScanRefreshing = true;
    } else {
      isScanLoading = true;
    }

    try {
      const data = await fetchWifiScan(refresh);
      scanNetworks = data;
      hasLoadedInitialScan = true;
      if (refresh) {
        toast.info('Wi-Fi scan updated', 3000);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Failed to scan Wi-Fi networks';
      toast.error(message);
    } finally {
      isScanLoading = false;
      isScanRefreshing = false;
    }
  }

  async function loadSaved() {
    isSavedLoading = true;
    try {
      savedNetworks = await fetchSavedNetworks();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Failed to load saved profiles';
      toast.error(message);
    } finally {
      isSavedLoading = false;
    }
  }

  async function refreshAll() {
    try {
      const [statusData, savedData] = await Promise.all([
        fetchWifiStatus(),
        fetchSavedNetworks(),
      ]);
      wifiStatus = statusData;
      savedNetworks = savedData;
    } catch {
      // Individual poll / fetch failures handled in components
    }
  }

  function handleStatusUpdate(newStatus: WifiStatus) {
    wifiStatus = newStatus;
  }

  function handleSelectNetwork(network: ScanNetwork) {
    selectedNetworkForJoin = network;
    isJoinDialogOpen = true;
  }

  function handleCloseJoinDialog() {
    isJoinDialogOpen = false;
  }

  async function handleConnectSuccess(ssid: string, ip: string) {
    toast.success(`Connected to ${ssid} (${ip})`);
    await refreshAll();
    // Non-blocking background rescan to update markers
    loadScan(false);
  }

  async function handleSavedConnect(item: SavedNetwork) {
    // If the network is also found in scan results, open join dialog or connect directly
    const foundInScan = scanNetworks.find((n) => n.ssid === item.ssid);
    if (foundInScan) {
      handleSelectNetwork(foundInScan);
      return;
    }

    // Direct connect with saved credentials
    try {
      toast.info(`Connecting to ${item.ssid}...`);
      const res = await connectWifi(item.ssid);
      toast.success(`Connected to ${res.ssid} (${res.ip})`);
      await refreshAll();
      loadScan(false);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : `Failed to connect to ${item.ssid}`;
      toast.error(message);
      // Open dialog so user can re-enter passphrase if needed
      selectedNetworkForJoin = {
        ssid: item.ssid,
        bssid: '—',
        signal: 0,
        frequency: 0,
        security: 'wpa2-psk',
        inUse: false,
        saved: true,
      };
      isJoinDialogOpen = true;
    }
  }

  async function handleForgetNetwork(ssid: string) {
    try {
      await forgetWifi(ssid);
      toast.success(`Profile for "${ssid}" forgotten`);
      await loadSaved();
      // Update saved flag on scan networks
      scanNetworks = scanNetworks.map((n) =>
        n.ssid === ssid ? { ...n, saved: false } : n
      );
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : `Failed to forget ${ssid}`;
      toast.error(message);
    }
  }

  onMount(() => {
    loadScan(false);
    loadSaved();
  });
</script>

<div class="app-layout">
  <Header />

  {#if wifiStatus}
    <PortalBanner status={wifiStatus} />
  {/if}

  <main class="main-content">
    <div class="top-row">
      <div class="top-col">
        <UplinkCard status={wifiStatus} onStatusChange={handleStatusUpdate} />
      </div>
      <div class="top-col">
        <SavedList
          {savedNetworks}
          isLoading={isSavedLoading}
          onConnect={handleSavedConnect}
          onForget={handleForgetNetwork}
        />
      </div>
    </div>

    <div class="scan-section">
      <ScanTable
        networks={scanNetworks}
        isLoading={isScanLoading}
        isRefreshing={isScanRefreshing}
        hasLoadedInitial={hasLoadedInitialScan}
        onSelectNetwork={handleSelectNetwork}
        onRefresh={() => loadScan(true)}
      />
    </div>
  </main>

  <JoinDialog
    network={selectedNetworkForJoin}
    isOpen={isJoinDialogOpen}
    onClose={handleCloseJoinDialog}
    onConnectSuccess={handleConnectSuccess}
  />

  <Toasts />
</div>

<style>
  .app-layout {
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    background-color: var(--color-bg);
  }

  .main-content {
    flex: 1;
    max-width: var(--max-width);
    width: 100%;
    margin: 0 auto;
    padding: var(--space-5) var(--space-4) var(--space-8);
    display: flex;
    flex-direction: column;
    gap: var(--space-5);
  }

  .top-row {
    display: grid;
    grid-template-columns: 1fr;
    gap: var(--space-5);
  }

  @media (min-width: 840px) {
    .top-row {
      grid-template-columns: 1.1fr 0.9fr;
      align-items: start;
    }
  }

  .scan-section {
    width: 100%;
  }
</style>
