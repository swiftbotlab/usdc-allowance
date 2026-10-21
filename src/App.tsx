import React, { useEffect } from 'react'
import { HashRouter, Routes, Route, Navigate } from 'react-router-dom'
import { useAccount, useSwitchChain } from 'wagmi'
import { Layout } from './components/Layout'
import { ErrorBoundary } from './components/ErrorBoundary'
import { OwnerPage } from './pages/OwnerPage'
import { NewAllowancePage } from './pages/NewAllowancePage'
import { AllowancePage } from './pages/AllowancePage'
import { SpenderPage } from './pages/SpenderPage'
import { DemoPage } from './pages/DemoPage'
import { useNetwork } from './hooks/useNetwork'
import { NETWORKS } from './config/networks'

// NetworkGuard: switches wagmi chain when the route's network changes
function NetworkGuard({ routeNetwork }: { routeNetwork: 'mainnet' | 'testnet' }) {
  const { network, setNetwork } = useNetwork()
  const { chainId } = useAccount()
  const { switchChain } = useSwitchChain()

  useEffect(() => {
    if (network !== routeNetwork) setNetwork(routeNetwork)
  }, [routeNetwork, network, setNetwork])

  useEffect(() => {
    const expectedId = NETWORKS[routeNetwork].chain.id
    if (chainId !== undefined && chainId !== expectedId) {
      switchChain({ chainId: expectedId })
    }
  }, [routeNetwork, chainId, switchChain])

  return null
}

function NetworkedRoutes({ net }: { net: 'mainnet' | 'testnet' }) {
  return (
    <>
      <NetworkGuard routeNetwork={net} />
      <Routes>
        <Route path="" element={<OwnerPage />} />
        <Route path="new" element={<NewAllowancePage />} />
        <Route path="a/:id" element={<AllowancePage />} />
        <Route path="spend" element={<SpenderPage />} />
        <Route path="demo" element={<DemoPage />} />
      </Routes>
    </>
  )
}

export default function App() {
  return (
    <ErrorBoundary>
      <HashRouter>
        <Layout>
          <Routes>
            {/* Default to mainnet */}
            <Route path="/" element={<Navigate to="/mainnet" replace />} />

            {/* Mainnet routes */}
            <Route path="/mainnet/*" element={<NetworkedRoutes net="mainnet" />} />

            {/* Testnet routes */}
            <Route path="/testnet/*" element={<NetworkedRoutes net="testnet" />} />

            {/* Catch-all */}
            <Route path="*" element={<Navigate to="/mainnet" replace />} />
          </Routes>
        </Layout>
      </HashRouter>
    </ErrorBoundary>
  )
}
