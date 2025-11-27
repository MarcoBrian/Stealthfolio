import React from "react";

export const BuildersSection: React.FC = () => {
  return (
    <section className="section" id="for-builders">
      <div className="section-header">
        <h2>For protocol builders and funds</h2>
        <p>
          Use Stealthfolio to ship private portfolio products without sacrificing
          decentralization or composability.
        </p>
      </div>
      <div className="builder-grid">
        <div className="builder-card">
          <h3>On-chain funds</h3>
          <p>
            Launch strategies that rebalance transparently on-chain while keeping
            allocation logic proprietary to your LPs.
          </p>
        </div>
        <div className="builder-card">
          <h3>Structured products</h3>
          <p>
            Wrap complex multi-asset strategies into a single user-facing
            instrument, with encrypted execution parameters.
          </p>
        </div>
        <div className="builder-card">
          <h3>DeFi protocols</h3>
          <p>
            Plug Stealthfolio into vaults and lending markets to offer
            privacy-preserving rebalancing for your users.
          </p>
        </div>
      </div>
    </section>
  );
};


