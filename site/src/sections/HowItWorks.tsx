import { motion, useReducedMotion, type Variants } from 'motion/react';
import { Heading } from '@astryxdesign/core/Heading';
import { Text } from '@astryxdesign/core/Text';
import { InView } from '../components/motion-primitives/in-view';

const codexChecks = [
  'A fresh reading shows 3% or less of the week left.',
  'A second reading, at least 5 seconds later, agrees.',
  'The week won’t renew on its own for at least 5 minutes.',
  'It redeems the saved reset that expires first.',
];

// The rail draws top to bottom while each step's marker lands in turn,
// so the order of the checks reads as a sequence rather than a list.
const railVariants: Variants = {
  hidden: { scaleY: 0 },
  visible: { scaleY: 1, transition: { duration: 0.9, ease: [0.65, 0, 0.35, 1] } },
};

const stepVariants: Variants = {
  hidden: { opacity: 0, x: -8 },
  visible: (index: number) => ({
    opacity: 1,
    x: 0,
    transition: { delay: 0.12 + index * 0.18, duration: 0.45, ease: [0.16, 1, 0.3, 1] },
  }),
};

export function HowItWorks() {
  const reduceMotion = useReducedMotion();
  return (
    <section className="section" id="what-it-does" aria-labelledby="what-title">
      <div className="container">
        <header className="section__head">
          <Heading level={2} className="section__title" textWrap="balance">
            <span id="what-title">What it does</span>
          </Heading>
        </header>
        <div className="compare">
          <article className="compare__col">
            <Heading level={3} className="compare__title">
              Codex redeems a saved reset for you
            </Heading>
            <Text as="p" color="secondary" className="prose">
              For each Codex account you see how much of the week is left, when it renews and how
              many resets you have saved. Turn on auto-redeem and it uses a reset only when all of
              this is true:
            </Text>
            <InView
              viewOptions={{ once: true, margin: '0px 0px -15% 0px' }}
              variants={{ hidden: {}, visible: {} }}
            >
              <div className="steps">
                <motion.span
                  className="steps__rail"
                  variants={reduceMotion ? undefined : railVariants}
                  aria-hidden="true"
                />
                <ol className="steps__list">
                  {codexChecks.map((step, index) => (
                    <motion.li
                      key={step}
                      className="steps__item"
                      custom={index}
                      variants={reduceMotion ? undefined : stepVariants}
                    >
                      <span className="steps__marker" aria-hidden="true" />
                      {step}
                    </motion.li>
                  ))}
                </ol>
              </div>
            </InView>
            <Text as="p" color="secondary" className="prose">
              It redeems through the official Codex app-server and never spends the same reset
              twice. 5-hour and per-model limits never trigger it.
            </Text>
          </article>
          <article className="compare__col">
            <Heading level={3} className="compare__title">
              Claude warns you and opens the reset page
            </Heading>
            <Text as="p" color="secondary" className="prose">
              For each Claude Pro or Max account you see the 5-hour, weekly and per-model limits.
              Checking is free. It uses Claude Code&rsquo;s own <code>/usage</code> command, which
              doesn&rsquo;t send a prompt to a model or count against your limits.
            </Text>
            <Text as="p" color="secondary" className="prose">
              When a limit drops to 10% you get one notification. <strong>Use a reset</strong> opens
              Claude&rsquo;s usage settings, where you can reset it yourself if Anthropic has given you
              one. Anthropic doesn&rsquo;t let other apps do that step, so Second Wind doesn&rsquo;t
              try.
            </Text>
          </article>
        </div>
      </div>
    </section>
  );
}
