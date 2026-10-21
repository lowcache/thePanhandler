export type WifiSecurity =
  | 'open'
  | 'owe'
  | 'wep'
  | 'wpa-psk'
  | 'wpa2-psk'
  | 'wpa3-sae'
  | 'enterprise';

export type WifiState =
  | 'activated'
  | 'activating'
  | 'deactivating'
  | 'disconnected'
  | 'unavailable'
  | 'unknown';

export type Connectivity = 'full' | 'portal' | 'limited' | 'none' | 'unknown';

export type PersistState = 'unlocked' | 'locked';

export type StorageType = 'disk' | 'memory' | 'base';

export interface WifiStatus {
  connected: boolean;
  uplinkSsid: string;
  bssid: string;
  ip: string;
  signal: number; // 0-100
  frequency: number; // MHz
  state: WifiState;
  connectivity: Connectivity;
  persist: PersistState;
  portalBypass: PortalBypass;
}

export interface PortalBypass {
  active: boolean;
  secondsLeft: number;
}

// Plain-HTTP URL the hotel intercepts and redirects to its login page.
export const PORTAL_PROBE_URL = 'http://nmcheck.gnome.org/check_network_status.txt';

export interface ScanNetwork {
  ssid: string;
  bssid: string;
  signal: number;
  frequency: number;
  security: WifiSecurity;
  inUse: boolean;
  saved: boolean;
}

export interface SavedNetwork {
  ssid: string;
  id: string;
  storage: StorageType;
  protected: boolean;
  autoconnect: boolean;
}

export interface ConnectResponse {
  status: 'connected';
  ssid: string;
  ip: string;
  storage: 'disk' | 'memory';
}

export interface ForgetResponse {
  status: 'forgotten';
  ssid: string;
}

interface ApiErrorPayload {
  error?: string;
  message?: string;
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const headers = new Headers(options?.headers);
  headers.set('Accept', 'application/json');
  if (options?.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }

  const res = await fetch(path, {
    ...options,
    headers,
  });

  if (!res.ok) {
    let errorMsg = `HTTP ${res.status}`;
    try {
      const data = (await res.json()) as ApiErrorPayload;
      if (data && typeof data.error === 'string' && data.error.length > 0) {
        errorMsg = data.error;
      } else if (data && typeof data.message === 'string' && data.message.length > 0) {
        errorMsg = data.message;
      }
    } catch {
      const text = await res.text().catch(() => '');
      if (text) {
        errorMsg = text;
      }
    }
    throw new Error(errorMsg);
  }

  return (await res.json()) as T;
}

export async function fetchWifiStatus(): Promise<WifiStatus> {
  return request<WifiStatus>('/api/wifi/status');
}

export async function fetchWifiScan(refresh = false): Promise<ScanNetwork[]> {
  const q = refresh ? '?refresh=1' : '';
  return request<ScanNetwork[]>(`/api/wifi/scan${q}`);
}

export async function fetchSavedNetworks(): Promise<SavedNetwork[]> {
  return request<SavedNetwork[]>('/api/wifi/saved');
}

export async function connectWifi(ssid: string, passphrase?: string, selection?: Pick<ScanNetwork, 'bssid' | 'security'>): Promise<ConnectResponse> {
  const body: { ssid: string; passphrase?: string; bssid?: string; security?: WifiSecurity } = { ssid, ...selection };
  if (passphrase !== undefined && passphrase !== '') {
    body.passphrase = passphrase;
  }
  return request<ConnectResponse>('/api/wifi/connect', {
    method: 'POST',
    body: JSON.stringify(body),
  });
}

export async function forgetWifi(ssid: string): Promise<ForgetResponse> {
  return request<ForgetResponse>('/api/wifi/forget', {
    method: 'POST',
    body: JSON.stringify({ ssid }),
  });
}

export async function setPortalBypass(enable: boolean): Promise<PortalBypass> {
  return request<PortalBypass>('/api/portal/bypass', {
    method: 'POST',
    body: JSON.stringify({ enable }),
  });
}

export function frequencyToBand(frequency: number): string {
  if (frequency >= 2400 && frequency <= 2500) {
    return '2.4 GHz';
  }
  if (frequency >= 4900 && frequency <= 5900) {
    return '5 GHz';
  }
  if (frequency >= 5925 && frequency <= 7125) {
    return '6 GHz';
  }
  if (frequency > 0) {
    return `${(frequency / 1000).toFixed(1)} GHz`;
  }
  return '—';
}

export function formatSecurity(security: WifiSecurity): string {
  switch (security) {
    case 'open':
      return 'Open';
    case 'owe':
      return 'OWE';
    case 'wep':
      return 'WEP';
    case 'wpa-psk':
      return 'WPA';
    case 'wpa2-psk':
      return 'WPA2';
    case 'wpa3-sae':
      return 'WPA3';
    case 'enterprise':
      return 'Enterprise';
    default:
      return security;
  }
}
