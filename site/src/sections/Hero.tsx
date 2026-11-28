import { useReducedMotion } from 'motion/react';
import { Button } from '@astryxdesign/core/Button';
import { Heading } from '@astryxdesign/core/Heading';
import { Link } from '@astryxdesign/core/Link';
import { Text } from '@astryxdesign/core/Text';
import { AnimatedGroup } from '../components/motion-primitives/animated-group';
import { ScreenShowcase } from '../components/ScreenShowcase';
import { ArrowDown, ArrowUpRight, Download } from '../components/icons';
import { REPO_URL } from '../config';
import { INSTALL } from '../install';

// Key poses: hidden (12px low, transparent) -> rest. Expo ease-out, 70 ms stagger,
// so the icon and name lead and the actions arrive last.
const textVariants = {
  container: { visible: { transition: { staggerChildren: 0.07 } } },
  item: {
    hidden: { opacity: 0, y: 12 },
    visible: { opacity: 1, y: 0, transition: { duration: 0.6, ease: [0.16, 1, 0.3, 1] } },
  },
};

// With reduced motion the copy is simply there at first paint.
const stillVariants = { container: {}, item: {} };

// A verified app downloads straight from the hero; otherwise the source steps are below.
const primaryAction =
  INSTALL.kind === 'app'
    ? { href: INSTALL.app.url, label: 'Download for Mac', endContent: <Download /> }
    : { href: '#install', label: 'Install from source', endContent: <ArrowDown /> };

const version = INSTALL.kind === 'app' ? `Version ${INSTALL.release.version}. ` : '';
const note = `${version}Free and open source. Not affiliated with OpenAI, Anthropic or Google.`;

export function Hero() {
  const reduceMotion = useReducedMotion();
  return (
    <section className="hero" id="top" aria-labelledby="hero-title">
      <div className="container">
        <AnimatedGroup className="hero__copy" variants={reduceMotion ? stillVariants : textVariants}>
          <img
            className="hero__icon"
            src="./app-icon.png"
            width={88}
            height={88}
            alt=""
            decoding="async"
          />
          <Heading level={1} type="display-1" className="hero__title">
            <span id="hero-title">Second Wind</span>
          </Heading>
          <Text as="p" size="lg" color="secondary" className="hero__lede" textWrap="pretty">
            See your Codex and Claude usage limits for every account, plus your Antigravity quota,
            in the Mac menu bar. When a limit runs low, it helps you use a reset before you run out.
          </Text>
          <div className="hero__actions">
            <Button
              href={primaryAction.href}
              label={primaryAction.label}
              variant="primary"
              size="lg"
              endContent={primaryAction.endContent}
            />
            <Button
              href={REPO_URL}
              label="View on GitHub"
              variant="secondary"
              size="lg"
              endContent={<ArrowUpRight />}
            />
          </div>
          <Text as="p" size="sm" color="secondary" className="hero__note">
            {note}
            {INSTALL.kind === 'app' && (
              <>
                {' '}
                <Link href="#install" size="sm">
                  First open takes one extra step
                </Link>
                .
              </>
            )}
          </Text>
        </AnimatedGroup>
        <ScreenShowcase />
      </div>
    </section>
  );
}
