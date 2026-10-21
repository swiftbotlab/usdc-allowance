import React, { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props { children: ReactNode }
interface State { error: Error | null }

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('ErrorBoundary caught:', error, info)
  }

  render() {
    if (this.state.error) {
      return (
        <div className="min-h-dvh flex items-center justify-center p-8 bg-gray-50">
          <div className="max-w-md w-full bg-white rounded-xl border border-red-200 p-6 space-y-4">
            <h2 className="text-lg font-semibold text-red-700">Something went wrong</h2>
            <p className="text-sm text-gray-600 font-mono bg-gray-50 p-3 rounded-lg break-all">
              {this.state.error.message}
            </p>
            <button
              onClick={() => this.setState({ error: null })}
              className="text-sm text-red-600 underline"
            >
              Try again
            </button>
          </div>
        </div>
      )
    }
    return this.props.children
  }
}
