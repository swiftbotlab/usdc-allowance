import { useState, useCallback } from 'react'
import { DEFAULT_NETWORK, getNetwork, NETWORKS, NetworkKey } from '../config/networks'

const LS_KEY = 'usdc-allowance:network'

function readStored(): NetworkKey {
  try {
    const v = localStorage.getItem(LS_KEY)
    return getNetwork(v ?? undefined)
  } catch {
    return DEFAULT_NETWORK
  }
}

// Singleton shared state — avoids context ceremony for a single enum
let _current: NetworkKey = readStored()
const _listeners = new Set<() => void>()

function setGlobal(k: NetworkKey) {
  _current = k
  try { localStorage.setItem(LS_KEY, k) } catch { /* ignore */ }
  _listeners.forEach(fn => fn())
}

export function useNetwork() {
  const [, rerender] = useState(0)

  const subscribe = useCallback(() => {
    const fn = () => rerender(n => n + 1)
    _listeners.add(fn)
    return () => _listeners.delete(fn)
  }, [])

  // Subscribe on first render
  useState(() => { subscribe() })

  const setNetwork = useCallback((k: NetworkKey) => setGlobal(k), [])

  return { network: _current, setNetwork, cfg: NETWORKS[_current] }
}
