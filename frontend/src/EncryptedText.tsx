import React, { useEffect, useState } from "react";

interface EncryptedTextProps {
  text: string;
  delay?: number;
  duration?: number;
  className?: string;
}

const CHARS = "!@#$%^&*()_+-=<>?/{}[]ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

export const EncryptedText: React.FC<EncryptedTextProps> = ({
  text,
  delay = 200,
  duration = 1200,
  className
}) => {
  const [display, setDisplay] = useState("");

  useEffect(() => {
    let startTime: number | null = null;
    let intervalId: number | null = null;

    // keep a stable array of scrambled chars and only mutate some of them
    let scrambled: string[] = Array.from({ length: text.length }).map(
      () => CHARS[Math.floor(Math.random() * CHARS.length)] ?? "?"
    );

    const tick = () => {
      const now = performance.now();
      if (startTime === null) startTime = now;
      const elapsed = now - startTime;

      if (elapsed < delay) {
        // initial fully encrypted state (stable, not re-randomized every frame)
        setDisplay(scrambled.join(""));
        return;
      }

      const total = delay + duration;
      if (elapsed >= total) {
        setDisplay(text);
        if (intervalId !== null) {
          window.clearInterval(intervalId);
        }
        return;
      }

      const progress = (elapsed - delay) / duration;
      const revealCount = Math.floor(progress * text.length);

      // gradually reveal characters from left to right
      for (let i = 0; i < revealCount; i++) {
        scrambled[i] = text[i] ?? "";
      }

      // softly animate the unrevealed tail: only change some characters,
      // not the whole string, to avoid a heavy flicker
      for (let i = revealCount; i < text.length; i++) {
        if (Math.random() < 0.2) {
          scrambled[i] = CHARS[Math.floor(Math.random() * CHARS.length)] ?? "?";
        }
      }

      setDisplay(scrambled.join(""));
    };

    // run at ~20fps instead of every animation frame to reduce visual noise
    intervalId = window.setInterval(tick, 50);

    // do an initial tick so there is content before the first interval fires
    tick();

    return () => {
      if (intervalId !== null) {
        window.clearInterval(intervalId);
      }
    };
  }, [text, delay, duration]);

  return <span className={className}>{display}</span>;
};


