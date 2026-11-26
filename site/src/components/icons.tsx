function Glyph({ d }: { d: string }) {
  return (
    <svg className="icon" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export const ArrowUpRight = () => <Glyph d="M5 11 11 5M6 5h5v5" />;
export const ArrowDown = () => <Glyph d="M8 3v10M4 9l4 4 4-4" />;
export const Download = () => <Glyph d="M8 2.5v8M4.5 7 8 10.5 11.5 7M3 13.5h10" />;
