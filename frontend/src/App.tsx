import React from "react";
import logo from "./logo.png";
import { Hero } from "./sections/Hero";
import { ProductSection } from "./sections/ProductSection";
import { HowItWorksSection } from "./sections/HowItWorksSection";
import { BuildersSection } from "./sections/BuildersSection";

export const App: React.FC = () => {
  return (
    <div className="page">
      <header className="nav">
        <div className="nav-left">
          <div className="logo-mark">
            <img src={logo} alt="Stealthfolio logo" className="logo-image" />
          </div>
          <span className="logo-text">Stealthfolio</span>
        </div>
        <nav className="nav-links">
          <a href="#product">Product</a>
          <a href="#how-it-works">How it works</a>
          <a href="#for-builders">For builders</a>
        </nav>
        <div className="nav-right">
          <button className="nav-btn nav-btn-outline">Docs</button>
          <button className="nav-btn nav-btn-primary">Launch App</button>
        </div>
      </header>

      <main>
        <Hero />
        <ProductSection />
        <HowItWorksSection />
        <BuildersSection />
      </main>

      <footer className="footer">
        <span>© {new Date().getFullYear()} Stealthfolio. All rights reserved.</span>
        <div className="footer-links">
          <a href="#top">Back to top</a>
          <a href="#">Security</a>
          <a href="#">Contact</a>
        </div>
      </footer>
    </div>
  );
};


