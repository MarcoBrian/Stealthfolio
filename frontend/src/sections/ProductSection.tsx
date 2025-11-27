import React from "react";

export const ProductSection: React.FC = () => {
  return (
    <section className="section" id="product">
      <div className="section-header">
        <h2>Why Stealthfolio</h2>
        <p>
          Protect your portfolio construction edge while routing through the
          deepest on-chain liquidity.
        </p>
      </div>
      <div className="feature-grid">
        <div className="feature-card">
          <h3>True execution privacy</h3>
          <p>
            Orders, target weights, and rebalance cadence remain encrypted
            end-to-end. Market participants see final state changes, not the
            strategy that drove them.
          </p>
        </div>
        <div className="feature-card">
          <h3>Multi-pool rebalancing</h3>
          <p>
            Coordinate trades across multiple Uniswap v4 pools in a single
            encrypted transaction. Stealthfolio optimizes fills while
            preserving your intent.
          </p>
        </div>
        <div className="feature-card">
          <h3>Institutional-grade controls</h3>
          <p>
            Express constraints — max slippage, per-asset bounds, venue
            allowlists — in encrypted form. The hook enforces them without ever
            learning the raw parameters.
          </p>
        </div>
        <div className="feature-card">
          <h3>Composable by design</h3>
          <p>
            Integrate Stealthfolio as a Uniswap v4 hook into existing DeFi
            infrastructure, vaults, and on-chain funds with minimal surface
            area.
          </p>
        </div>
      </div>
    </section>
  );
};


