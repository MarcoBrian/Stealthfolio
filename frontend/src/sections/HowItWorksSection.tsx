import React from "react";

export const HowItWorksSection: React.FC = () => {
  return (
    <section className="section section-split" id="how-it-works">
      <div className="section-column">
        <h2>How it works</h2>
        <p className="muted">
          Fhenix FHE lets Stealthfolio evaluate your rebalance program over
          encrypted inputs inside a Uniswap v4 hook. The chain never sees the
          plaintext strategy.
        </p>
        <ol className="steps">
          <li>
            <span className="step-number">1</span>
            <div>
              <h3>Encrypt your strategy</h3>
              <p>
                Encode target allocations, constraints, and timing into an
                encrypted payload using Fhenix FHE primitives.
              </p>
            </div>
          </li>
          <li>
            <span className="step-number">2</span>
            <div>
              <h3>Attach to a Uniswap v4 pool</h3>
              <p>
                Deploy Stealthfolio as a hook on the pools your portfolio routes
                through, without changing pool mechanics.
              </p>
            </div>
          </li>
          <li>
            <span className="step-number">3</span>
            <div>
              <h3>Encrypted rebalancing</h3>
              <p>
                On rebalance, the hook evaluates your program homomorphically and
                executes trades that respect your encrypted constraints.
              </p>
            </div>
          </li>
        </ol>
      </div>
      <div className="section-column glass-panel">
        <p className="panel-label">Hook telemetry (redacted)</p>
        <div className="telemetry-row">
          <span>Assets</span>
          <span className="blurred">[3]</span>
        </div>
        <div className="telemetry-row">
          <span>Total notional</span>
          <span className="blurred">&gt; $10M</span>
        </div>
        <div className="telemetry-row">
          <span>Slippage ceiling</span>
          <span className="blurred">&lt; 0.3%</span>
        </div>
        <div className="telemetry-row">
          <span>Strategy type</span>
          <span className="blurred">Market-neutral</span>
        </div>
        <p className="telemetry-footnote">
          All sensitive fields are represented as ciphertext on-chain. Plain
          values shown here are for illustration only.
        </p>
      </div>
    </section>
  );
};


