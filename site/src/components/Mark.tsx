// The gust mark, drawn from the same three strokes as the app icon.
export function Mark({ size = 28 }: { size?: number }) {
  return (
    <svg
      className="mark"
      viewBox="200 220 600 620"
      width={size}
      height={size}
      aria-hidden="true"
      focusable="false"
    >
      <path d="M262 420H640A71 71 0 1 0 586 302" />
      <path d="M262 536H742" opacity="0.85" />
      <path d="M262 652H562A70 70 0 1 1 508 767" opacity="0.7" />
    </svg>
  );
}

export function Wordmark() {
  return (
    <span className="wordmark">
      <Mark />
      <span>Second Wind</span>
    </span>
  );
}
