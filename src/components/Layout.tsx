import React, { type ReactNode } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { ConnectKitButton } from 'connectkit'
import { useNetwork } from '../hooks/useNetwork'
import type { NetworkKey } from '../config/networks'

interface LayoutProps { children: ReactNode }

export function Layout({ children }: LayoutProps) {
  const { network, setNetwork, cfg } = useNetwork()
  const loc = useLocation()

  // Derive active nav from hash path
  const path = loc.hash.replace('#', '') || '/'
  const isOwner   = path === `/${network}` || path === `/${network}/` || path === `/${network}/new` || path.startsWith(`/${network}/a/`)
  const isSpender = path === `/${network}/spend`
  const isDemo    = path === `/${network}/demo`

  const navLink = (to: string, label: string, active: boolean) => (
    <Link
      to={to}
      className={`text-sm font-medium px-3 py-1.5 rounded-md transition-colors ${
        active
          ? 'bg-red-50 text-red-700'
          : 'text-gray-600 hover:text-gray-900 hover:bg-gray-100'
      }`}
    >
      {label}
    </Link>
  )

  const toggleNetwork = () => {
    const next: NetworkKey = network === 'mainnet' ? 'testnet' : 'mainnet'
    setNetwork(next)
    // Navigate to root of new network
    window.location.hash = `#/${next}`
  }

  return (
    <div className="min-h-dvh bg-gray-50 font-sans flex flex-col">
      {/* Testnet banner */}
      {network === 'testnet' && (
        <div className="bg-yellow-50 border-b border-yellow-200 text-yellow-800 text-xs text-center py-1.5 px-4 font-medium sticky top-0 z-50">
          Arc Testnet — test USDC only, no real value
        </div>
      )}

      {/* Header */}
      <header className="bg-white border-b border-gray-200 sticky top-0 z-40">
        <div className="max-w-5xl mx-auto px-4 h-14 flex items-center gap-3">
          {/* Brand */}
          <Link to={`/${network}`} className="flex items-center gap-2 mr-2 shrink-0">
            <div className="w-7 h-7 rounded-md bg-red-600 flex items-center justify-center">
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <rect x="1" y="5" width="12" height="4" rx="1" fill="white" opacity=".9"/>
                <rect x="5" y="1" width="4" height="12" rx="1" fill="white" opacity=".6"/>
              </svg>
            </div>
            <span className="font-semibold text-gray-900 text-sm hidden sm:block">USDC Allowance</span>
          </Link>

          {/* Nav */}
          <nav className="flex items-center gap-1 flex-1">
            {navLink(`/${network}`, 'Owner', isOwner)}
            {navLink(`/${network}/spend`, 'Spender', isSpender)}
            {navLink(`/${network}/demo`, 'Demo', isDemo)}
          </nav>

          {/* Network toggle */}
          <button
            onClick={toggleNetwork}
            className={`text-xs font-semibold px-2.5 py-1 rounded-full border transition-colors ${
              network === 'mainnet'
                ? 'border-gray-300 text-gray-600 hover:border-gray-400'
                : 'border-yellow-400 text-yellow-700 bg-yellow-50 hover:bg-yellow-100'
            }`}
          >
            {network === 'mainnet' ? 'Mainnet' : 'Testnet'}
          </button>

          {/* Wallet */}
          <ConnectKitButton.Custom>
            {({ isConnected, show, address, truncatedAddress }) => (
              <button
                onClick={show}
                className={`text-sm font-medium px-3 py-1.5 rounded-lg transition-colors min-h-[36px] ${
                  isConnected
                    ? 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                    : 'bg-red-600 text-white hover:bg-red-700'
                }`}
              >
                {isConnected ? (truncatedAddress ?? shortAddr(address ?? '')) : 'Connect'}
              </button>
            )}
          </ConnectKitButton.Custom>
        </div>
      </header>

      {/* Main */}
      <main className="flex-1">
        {children}
      </main>

      {/* Footer */}
      <footer className="border-t border-gray-200 bg-white py-4 mt-8">
        <div className="max-w-5xl mx-auto px-4 flex flex-wrap items-center justify-between gap-3 text-xs text-gray-400">
          <div className="flex items-center gap-3">
            <a
              href={`${cfg.explorerBase}/address/${cfg.address}`}
              target="_blank"
              rel="noopener noreferrer"
              className="hover:text-gray-600 transition-colors"
            >
              Contract on {network === 'mainnet' ? 'Arc Mainnet' : 'Arc Testnet'}
            </a>
          </div>
          <span>Swift Bot Labs</span>
        </div>
      </footer>
    </div>
  )
}

function shortAddr(addr: string) {
  if (!addr || addr.length < 10) return addr
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}
