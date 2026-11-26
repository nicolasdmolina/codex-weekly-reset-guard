import { useId, useRef, useState, type KeyboardEvent } from 'react';
import { motion, useReducedMotion, type Variants } from 'motion/react';
import { TransitionPanel } from './motion-primitives/transition-panel';
import { useMediaQuery } from '../hooks/useMediaQuery';
import { SCREEN_HEIGHT, SCREEN_WIDTH, desktopScreens, screens } from './screens';

export function ScreenShowcase() {
  const wide = useMediaQuery('(min-width: 900px)');
  return wide ? <ScreenRow /> : <ScreenTabs />;
}

// Desktop: three real states side by side. The centre shot leads; the side shots
// start tucked behind it and fan out on an arc (x eases out while y springs),
// then settle with a small overshoot. Captions follow once the shots land.
const shotVariants: Variants = {
  hidden: (side: number) => ({ opacity: 0, y: 64, x: side * -56, rotate: side * -2 }),
  visible: (side: number) => ({
    opacity: 1,
    y: side === 0 ? 0 : 32,
    x: 0,
    rotate: 0,
    transition: {
      delay: side === 0 ? 0.32 : 0.44,
      opacity: { duration: 0.35, delay: side === 0 ? 0.32 : 0.44 },
      x: { duration: 0.9, ease: [0.16, 1, 0.3, 1], delay: side === 0 ? 0.32 : 0.44 },
      y: { type: 'spring', stiffness: 110, damping: 17, mass: 1, delay: side === 0 ? 0.32 : 0.44 },
      rotate: { type: 'spring', stiffness: 120, damping: 14, delay: side === 0 ? 0.32 : 0.44 },
    },
  }),
};

const captionVariants: Variants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1, transition: { delay: 1.05, duration: 0.5 } },
};

function ScreenRow() {
  const reduceMotion = useReducedMotion();
  return (
    <div className="showcase" role="list" aria-label="Second Wind in three states">
      {desktopScreens.map((screen, position) => {
        const side = position - 1;
        return (
          <motion.figure
            key={screen.id}
            role="listitem"
            className={`showcase__item${side === 0 ? ' showcase__item--lead' : ''}`}
            custom={side}
            variants={shotVariants}
            initial={reduceMotion ? false : 'hidden'}
            animate="visible"
          >
            <div className="shot">
              <img
                src={screen.src}
                width={SCREEN_WIDTH}
                height={SCREEN_HEIGHT}
                alt={screen.alt}
                fetchPriority={side === 0 ? 'high' : 'auto'}
                decoding="async"
              />
            </div>
            <motion.figcaption variants={captionVariants} className="showcase__caption">
              {screen.caption}
            </motion.figcaption>
          </motion.figure>
        );
      })}
    </div>
  );
}

const keyTargets = new Map<string, (index: number) => number>([
  ['ArrowRight', (index) => index + 1],
  ['ArrowLeft', (index) => index - 1],
  ['Home', () => 0],
  ['End', () => screens.length - 1],
]);

// Narrow screens: one shot at a time, switched by an accessible tab list.
// The selected index is the only state. The fill is drawn inside the selected
// tab, so it always sits on the tab that is aria-selected and focused.
function ScreenTabs() {
  const [activeIndex, setActiveIndex] = useState(0);
  const tabRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const baseId = useId();
  const panelId = `${baseId}-panel`;
  const tabId = (index: number) => `${baseId}-tab-${screens[index].id}`;

  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    const target = keyTargets.get(event.key);
    if (!target) return;
    event.preventDefault();
    const next = (target(activeIndex) + screens.length) % screens.length;
    setActiveIndex(next);
    tabRefs.current[next]?.focus();
  }

  return (
    <div className="screen-tabs">
      <div className="segmented" role="tablist" aria-label="App states" onKeyDown={onKeyDown}>
        {screens.map((screen, index) => {
          const selected = index === activeIndex;
          return (
            <button
              key={screen.id}
              ref={(node) => {
                tabRefs.current[index] = node;
              }}
              type="button"
              role="tab"
              id={tabId(index)}
              aria-selected={selected}
              aria-controls={panelId}
              tabIndex={selected ? 0 : -1}
              className="segmented__tab"
              onClick={() => setActiveIndex(index)}
            >
              {selected && (
                <motion.span
                  layoutId={`${baseId}-fill`}
                  className="segmented__fill"
                  transition={{ type: 'spring', bounce: 0.18, duration: 0.4 }}
                />
              )}
              <span className="segmented__label">{screen.tab}</span>
            </button>
          );
        })}
      </div>
      <div
        id={panelId}
        role="tabpanel"
        aria-labelledby={tabId(activeIndex)}
        tabIndex={0}
        className="screen-tabs__panel"
      >
        <TransitionPanel
          activeIndex={activeIndex}
          transition={{ duration: 0.32, ease: [0.16, 1, 0.3, 1] }}
          variants={{
            enter: { opacity: 0, y: 10, filter: 'blur(4px)' },
            center: { opacity: 1, y: 0, filter: 'blur(0px)' },
            exit: { opacity: 0, y: -6, filter: 'blur(4px)' },
          }}
        >
          {screens.map((screen) => (
            <figure key={screen.id} className="screen-tabs__figure">
              <div className="shot">
                <img src={screen.src} width={SCREEN_WIDTH} height={SCREEN_HEIGHT} alt={screen.alt} />
              </div>
              <figcaption className="showcase__caption">{screen.caption}</figcaption>
            </figure>
          ))}
        </TransitionPanel>
      </div>
    </div>
  );
}
