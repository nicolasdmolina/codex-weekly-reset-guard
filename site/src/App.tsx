import { MotionConfig } from 'motion/react';
import { Theme } from '@astryxdesign/core/theme';
import { secondWindTheme } from './theme';
import { SiteHeader } from './sections/SiteHeader';
import { Hero } from './sections/Hero';
import { HowItWorks } from './sections/HowItWorks';
import { Privacy } from './sections/Privacy';
import { Install } from './sections/Install';
import { Faq } from './sections/Faq';
import { SiteFooter } from './sections/SiteFooter';

export function App() {
  return (
    <Theme theme={secondWindTheme} mode="system">
      {/* "user" keeps opacity fades but drops movement under prefers-reduced-motion. */}
      <MotionConfig reducedMotion="user">
        <a className="skip-link" href="#main">
          Skip to content
        </a>
        <SiteHeader />
        <main id="main">
          <Hero />
          <HowItWorks />
          <Privacy />
          <Install />
          <Faq />
        </main>
        <SiteFooter />
      </MotionConfig>
    </Theme>
  );
}
