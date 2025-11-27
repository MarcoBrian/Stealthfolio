import React from "react";
import { EncryptedText } from "../EncryptedText";

export const Hero: React.FC = () => {
  return (
    <section className="hero" id="top">
      <div className="hero-text">
        <p className="eyebrow">Uniswap v4 FHE hook</p>
        <h1>
          <EncryptedText
            text="Confidential portfolio rebalancing."
            className="hero-title"
            delay={250}
            duration={1400}
          />
        </h1>
        <p className="hero-subtitle">
          Stealthfolio lets you rebalance across multiple Uniswap v4 pools
          without revealing target allocations, trade sizes, or strategy logic —
          secured by Fhenix Fully Homomorphic Encryption.
        </p>
        <div className="hero-actions">
          <button className="primary-cta">Start building</button>
          <button className="secondary-cta">View hook architecture</button>
        </div>
        <div className="hero-meta">
          <div>
            <span className="meta-label">Built for</span>
            <span className="meta-value">Uniswap v4 hooks</span>
          </div>
          <div>
            <span className="meta-label">Powered by</span>
            <span className="meta-value">Fhenix FHE</span>
          </div>
          <div>
            <span className="meta-label">Focus</span>
            <span className="meta-value">Strategy privacy</span>
          </div>
        </div>
      </div>

      <div className="hero-panel">
        <div className="panel-header">
          <span className="dot red" />
          <span className="dot amber" />
          <span className="dot green" />
          <span className="panel-title">Encrypted rebalance</span>
        </div>
        <div className="panel-body">
          <p className="panel-label">Encrypted strategy payload</p>
          <div className="cipher-block">
            <EncryptedText
              text="{ targetAllocations: [ETH, WBTC, USDC], maxSlippageBps: 30 }"
              delay={0}
              duration={2000}
              className="cipher-text"
            />
          </div>
          <div className="panel-grid">
            <div className="panel-card">
              <p className="card-label">On-chain view</p>
              <p className="card-value">Ciphertext only</p>
              <p className="card-desc">
                Observers see encrypted instructions, not target allocations or
                order sizing.
              </p>
            </div>
            <div className="panel-card">
              <p className="card-label">Hook logic</p>
              <p className="card-value">FHE compute</p>
              <p className="card-desc">
                Stealthfolio evaluates your rebalance program over encrypted data
                inside the hook.
              </p>
            </div>
            <div className="panel-card">
              <p className="card-label">Outcome</p>
              <p className="card-value">Optimal fills</p>
              <p className="card-desc">
                Routes liquidity across multiple pools without leaking strategy.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};


