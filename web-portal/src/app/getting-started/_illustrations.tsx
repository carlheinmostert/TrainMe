// Inline wireframe SVGs for the getting-started walkthrough. One per step.
// Style: 1.5px white/grey strokes on a dark elevated card; the active
// element is coral. No gradients, no shading. Server-rendered only.

const STROKE = '#9CA3AF';
const STROKE_DIM = '#4B5563';
const CORAL = '#FF6B35';
const SAGE = '#86EFAC';

type FrameProps = {
  children: React.ReactNode;
  caption?: string;
};

// Phone-shell frame. ~280px tall, ~180 wide canvas with iPhone outline.
function PhoneFrame({ children, caption }: FrameProps) {
  return (
    <figure className="my-6 flex flex-col items-center">
      <div className="rounded-xl border border-surface-border bg-surface-base p-6">
        <svg
          viewBox="0 0 200 360"
          width="200"
          height="280"
          role="img"
          aria-label={caption ?? 'Wireframe illustration'}
        >
          {/* Phone outline */}
          <rect
            x="6"
            y="6"
            width="188"
            height="348"
            rx="22"
            ry="22"
            fill="none"
            stroke={STROKE}
            strokeWidth="1.5"
          />
          {/* Notch */}
          <rect
            x="78"
            y="14"
            width="44"
            height="6"
            rx="3"
            fill={STROKE}
            opacity="0.6"
          />
          {/* Screen area: x=14 y=30 w=172 h=300 */}
          {children}
        </svg>
      </div>
      {caption && (
        <figcaption className="mt-2 text-xs text-ink-muted">
          {caption}
        </figcaption>
      )}
    </figure>
  );
}

// Small focused-control frame (no phone shell). For Refine sub-section accents.
function MiniFrame({ children, caption }: FrameProps) {
  return (
    <figure className="my-4 flex flex-col items-center">
      <div className="rounded-lg border border-surface-border bg-surface-base p-4">
        <svg
          viewBox="0 0 160 100"
          width="160"
          height="100"
          role="img"
          aria-label={caption ?? 'Control illustration'}
        >
          {children}
        </svg>
      </div>
      {caption && (
        <figcaption className="mt-2 max-w-[160px] text-center text-[11px] text-ink-muted">
          {caption}
        </figcaption>
      )}
    </figure>
  );
}

// ---------------------------------------------------------------------------
// Toolbar icons — used in the visual table-of-contents strip + step numbers.
// All draw on a 24×24 viewBox so callers can size with width/height.
// ---------------------------------------------------------------------------

type IconProps = {
  size?: number;
  color?: string;
  className?: string;
};

export function CameraIcon({ size = 24, color = CORAL, className }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke={color}
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      role="img"
      aria-label="Camera"
    >
      <rect x="3" y="7" width="14" height="11" rx="2" />
      <path d="M17 11l4-2.5v9L17 15z" />
      <circle cx="10" cy="12.5" r="2.2" />
    </svg>
  );
}

export function RefineIcon({ size = 24, color = CORAL, className }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke={color}
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      role="img"
      aria-label="Refine"
    >
      <line x1="5" y1="7" x2="19" y2="7" />
      <line x1="5" y1="12" x2="19" y2="12" />
      <line x1="5" y1="17" x2="19" y2="17" />
      <circle cx="5" cy="7" r="0.8" fill={color} />
      <circle cx="5" cy="12" r="0.8" fill={color} />
      <circle cx="5" cy="17" r="0.8" fill={color} />
    </svg>
  );
}

export function PreviewIcon({ size = 24, color = CORAL, className }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke={color}
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      role="img"
      aria-label="Preview"
    >
      <circle cx="12" cy="12" r="8.5" />
      <polygon points="10,8.5 16,12 10,15.5" fill={color} stroke="none" />
    </svg>
  );
}

export function PublishIcon({ size = 24, color = CORAL, className }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke={color}
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      role="img"
      aria-label="Publish"
    >
      <path d="M6.5 16.5a3.5 3.5 0 0 1 .4-6.97 5 5 0 0 1 9.7-1.2 4 4 0 0 1 .9 7.92" />
      <line x1="12" y1="11" x2="12" y2="18" />
      <polyline points="9,14 12,11 15,14" />
    </svg>
  );
}

export function ShareIcon({ size = 24, color = CORAL, className }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke={color}
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      role="img"
      aria-label="Share"
    >
      <path d="M7 11v8a1.5 1.5 0 0 0 1.5 1.5h7A1.5 1.5 0 0 0 17 19v-8" />
      <polyline points="8.5,7 12,3.5 15.5,7" />
      <line x1="12" y1="3.5" x2="12" y2="14" />
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Toolbar strip — visual table-of-contents that mocks the Studio bottom pill.
// ---------------------------------------------------------------------------

export function ToolbarStrip() {
  const items = [
    { label: 'Capture', Icon: CameraIcon },
    { label: 'Adjust', Icon: RefineIcon },
    { label: 'Preview', Icon: PreviewIcon },
    { label: 'Publish', Icon: PublishIcon },
    { label: 'Share', Icon: ShareIcon },
  ];
  return (
    <div className="my-8 flex flex-col items-center">
      <div className="flex items-center gap-1 rounded-full border border-surface-border bg-surface-base px-3 py-2 shadow-sm">
        {items.map(({ label, Icon }, i) => (
          <div key={label} className="flex items-center">
            <div
              className="flex h-9 w-9 items-center justify-center rounded-full bg-black/30"
              aria-label={label}
            >
              <Icon size={18} />
            </div>
            {i < items.length - 1 && (
              <div className="mx-0.5 text-ink-muted/40" aria-hidden="true">
                ·
              </div>
            )}
          </div>
        ))}
      </div>
      <div className="mt-2 flex items-center gap-1 text-[11px] text-ink-muted">
        {items.map((it, i) => (
          <span key={it.label} className="flex items-center">
            <span className="w-9 text-center">{it.label}</span>
            {i < items.length - 1 && <span className="mx-0.5 opacity-40">·</span>}
          </span>
        ))}
      </div>
      <p className="mt-3 max-w-md text-center text-xs text-ink-muted">
        <strong className="text-ink">CAPS</strong> &mdash; the Studio bottom
        toolbar. Five stages from a stack of clips to a link in your
        client&rsquo;s WhatsApp.
      </p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Step illustrations.
// ---------------------------------------------------------------------------

export function StepCreateClient() {
  return (
    <PhoneFrame caption="Step 1 — tap the coral + to create your first client">
      {/* Header */}
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Clients
      </text>
      <line x1="14" y1="58" x2="186" y2="58" stroke={STROKE_DIM} strokeWidth="1" />

      {/* Empty state hint */}
      <text
        x="100"
        y="180"
        fill={STROKE_DIM}
        fontSize="9"
        fontFamily="sans-serif"
        textAnchor="middle"
      >
        No clients yet
      </text>

      {/* FAB — coral plus */}
      <circle cx="160" cy="304" r="20" fill={CORAL} />
      <line x1="152" y1="304" x2="168" y2="304" stroke="white" strokeWidth="2.5" strokeLinecap="round" />
      <line x1="160" y1="296" x2="160" y2="312" stroke="white" strokeWidth="2.5" strokeLinecap="round" />

      {/* Arrow callout */}
      <line x1="120" y1="304" x2="138" y2="304" stroke={CORAL} strokeWidth="1.5" />
      <polygon points="138,300 138,308 144,304" fill={CORAL} />
      <text x="80" y="307" fill={CORAL} fontSize="9" fontFamily="sans-serif" textAnchor="end">
        tap +
      </text>
    </PhoneFrame>
  );
}

export function StepConsent() {
  return (
    <PhoneFrame caption="Step 2 — three video-treatment toggles, plus avatar and analytics">
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Sarah Jones
      </text>
      <line x1="22" y1="54" x2="100" y2="54" stroke={STROKE_DIM} strokeDasharray="2,2" strokeWidth="1" />

      {/* Section heading */}
      <text x="22" y="84" fill={STROKE} fontSize="9" fontFamily="sans-serif">
        Client consent
      </text>
      <polygon points="170,80 178,80 174,86" fill={STROKE} />

      {/* Three coral toggle pills */}
      <g>
        <rect x="22" y="100" width="156" height="22" rx="11" fill="none" stroke={STROKE_DIM} strokeWidth="1" />
        <circle cx="34" cy="111" r="6" fill={CORAL} />
        <text x="48" y="115" fill={STROKE} fontSize="9" fontFamily="sans-serif">
          Line drawing
        </text>
        <text x="170" y="115" fill={CORAL} fontSize="8" fontFamily="sans-serif" textAnchor="end">
          on
        </text>
      </g>
      <g>
        <rect x="22" y="130" width="156" height="22" rx="11" fill="none" stroke={STROKE_DIM} strokeWidth="1" />
        <circle cx="34" cy="141" r="6" fill={CORAL} />
        <text x="48" y="145" fill={STROKE} fontSize="9" fontFamily="sans-serif">
          Black &amp; white
        </text>
        <text x="170" y="145" fill={CORAL} fontSize="8" fontFamily="sans-serif" textAnchor="end">
          on
        </text>
      </g>
      <g>
        <rect x="22" y="160" width="156" height="22" rx="11" fill="none" stroke={STROKE_DIM} strokeWidth="1" />
        <circle cx="34" cy="171" r="6" fill="none" stroke={STROKE_DIM} strokeWidth="1" />
        <text x="48" y="175" fill={STROKE} fontSize="9" fontFamily="sans-serif">
          Original colour
        </text>
        <text x="170" y="175" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="end">
          off
        </text>
      </g>

      <line x1="22" y1="200" x2="178" y2="200" stroke={STROKE_DIM} strokeWidth="0.5" />

      <text x="22" y="220" fill={STROKE} fontSize="9" fontFamily="sans-serif">
        Avatar
      </text>
      <rect x="146" y="210" width="32" height="14" rx="7" fill={CORAL} opacity="0.85" />
      <circle cx="171" cy="217" r="5" fill="white" />

      <text x="22" y="248" fill={STROKE} fontSize="9" fontFamily="sans-serif">
        Analytics
      </text>
      <rect x="146" y="238" width="32" height="14" rx="7" fill={STROKE_DIM} opacity="0.6" />
      <circle cx="153" cy="245" r="5" fill="white" />
    </PhoneFrame>
  );
}

export function StepAvatar() {
  return (
    <PhoneFrame caption="Step 3 — tap the avatar circle to add a photo">
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Sarah Jones
      </text>

      {/* Avatar circle with coral plus indicator */}
      <circle cx="100" cy="120" r="36" fill="none" stroke={CORAL} strokeWidth="2" strokeDasharray="3,3" />
      <line x1="92" y1="120" x2="108" y2="120" stroke={CORAL} strokeWidth="2" strokeLinecap="round" />
      <line x1="100" y1="112" x2="100" y2="128" stroke={CORAL} strokeWidth="2" strokeLinecap="round" />

      <text x="100" y="178" fill={CORAL} fontSize="9" fontFamily="sans-serif" textAnchor="middle">
        + tap to add photo
      </text>

      {/* Sessions section placeholder */}
      <text x="22" y="220" fill={STROKE_DIM} fontSize="9" fontFamily="sans-serif">
        Sessions
      </text>
      <line x1="22" y1="226" x2="178" y2="226" stroke={STROKE_DIM} strokeWidth="0.5" />
      <rect x="22" y="240" width="156" height="36" rx="6" fill="none" stroke={STROKE_DIM} strokeWidth="0.5" strokeDasharray="2,3" />
      <text x="100" y="262" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        no sessions yet
      </text>
    </PhoneFrame>
  );
}

export function StepNewSession() {
  return (
    <PhoneFrame caption="Step 4 — tap New Session to enter capture mode">
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Sarah Jones
      </text>
      <circle cx="160" cy="46" r="12" fill="none" stroke={STROKE_DIM} strokeWidth="1" />

      <text x="22" y="86" fill={STROKE_DIM} fontSize="9" fontFamily="sans-serif">
        Sessions
      </text>
      <line x1="22" y1="92" x2="178" y2="92" stroke={STROKE_DIM} strokeWidth="0.5" />

      {/* Empty session list placeholder */}
      <rect x="22" y="106" width="156" height="36" rx="6" fill="none" stroke={STROKE_DIM} strokeWidth="0.5" strokeDasharray="2,3" />

      {/* New Session FAB */}
      <rect x="80" y="290" width="100" height="32" rx="16" fill={CORAL} />
      <text x="130" y="310" fill="white" fontSize="10" fontFamily="sans-serif" textAnchor="middle" fontWeight="600">
        + New Session
      </text>

      {/* Arrow callout */}
      <line x1="50" y1="306" x2="76" y2="306" stroke={CORAL} strokeWidth="1.5" />
      <polygon points="76,302 76,310 82,306" fill={CORAL} />
    </PhoneFrame>
  );
}

export function StepCamera() {
  return (
    <PhoneFrame caption="Capture — short-press for photo, long-press for video">
      {/* Viewfinder area */}
      <rect x="14" y="30" width="172" height="244" fill={STROKE_DIM} opacity="0.15" />

      {/* Crosshair-ish framing */}
      <line x1="14" y1="152" x2="186" y2="152" stroke={STROKE_DIM} strokeWidth="0.5" strokeDasharray="2,4" />
      <line x1="100" y1="30" x2="100" y2="274" stroke={STROKE_DIM} strokeWidth="0.5" strokeDasharray="2,4" />

      {/* Lens pills right edge */}
      <g>
        <rect x="166" y="100" width="14" height="14" rx="7" fill="none" stroke={STROKE} strokeWidth="0.8" />
        <text x="173" y="111" fill={STROKE} fontSize="7" fontFamily="sans-serif" textAnchor="middle">
          .5
        </text>
      </g>
      <g>
        <rect x="166" y="118" width="14" height="14" rx="7" fill="none" stroke={STROKE} strokeWidth="0.8" />
        <text x="173" y="129" fill={STROKE} fontSize="7" fontFamily="sans-serif" textAnchor="middle">
          1
        </text>
      </g>
      <g>
        <rect x="166" y="136" width="14" height="14" rx="7" fill="none" stroke={STROKE} strokeWidth="0.8" />
        <text x="173" y="147" fill={STROKE} fontSize="7" fontFamily="sans-serif" textAnchor="middle">
          2
        </text>
      </g>

      {/* Library peek bottom-left */}
      <rect x="22" y="240" width="22" height="22" rx="3" fill="none" stroke={STROKE_DIM} strokeWidth="1" />

      {/* Shutter — coral */}
      <circle cx="100" cy="304" r="22" fill="none" stroke={CORAL} strokeWidth="2" />
      <circle cx="100" cy="304" r="16" fill={CORAL} />

      {/* Hint text */}
      <text x="100" y="340" fill={CORAL} fontSize="9" fontFamily="sans-serif" textAnchor="middle">
        long-press = video
      </text>
    </PhoneFrame>
  );
}

export function StepStudio() {
  return (
    <PhoneFrame caption="Adjust — tap a card to open the editor sheet">
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Studio
      </text>

      {/* Workflow pill at top */}
      <rect x="40" y="60" width="120" height="14" rx="7" fill="none" stroke={STROKE_DIM} strokeWidth="0.8" />
      <text x="100" y="70" fill={STROKE_DIM} fontSize="6.5" fontFamily="sans-serif" textAnchor="middle">
        Cap · Adj · Prev · Pub · Share
      </text>

      {/* Gutter rail circuit indicator on left */}
      <line x1="20" y1="100" x2="20" y2="180" stroke={CORAL} strokeWidth="2" strokeLinecap="round" />
      <text x="14" y="142" fill={CORAL} fontSize="7" fontFamily="sans-serif" transform="rotate(-90 14 142)">
        circuit
      </text>

      {/* Stacked exercise cards */}
      <g>
        <rect x="30" y="98" width="148" height="36" rx="6" fill="none" stroke={CORAL} strokeWidth="1.5" />
        <rect x="36" y="104" width="24" height="24" rx="3" fill={STROKE_DIM} opacity="0.4" />
        <text x="68" y="116" fill={STROKE} fontSize="8" fontFamily="sans-serif">
          Squat
        </text>
        <text x="68" y="126" fill={STROKE_DIM} fontSize="7" fontFamily="sans-serif">
          3×10
        </text>
        <text x="170" y="120" fill={CORAL} fontSize="7" fontFamily="sans-serif" textAnchor="end">
          tap
        </text>
      </g>
      <g>
        <rect x="30" y="140" width="148" height="36" rx="6" fill="none" stroke={STROKE} strokeWidth="1" />
        <rect x="36" y="146" width="24" height="24" rx="3" fill={STROKE_DIM} opacity="0.4" />
        <text x="68" y="158" fill={STROKE} fontSize="8" fontFamily="sans-serif">
          Lunge
        </text>
        <text x="68" y="168" fill={STROKE_DIM} fontSize="7" fontFamily="sans-serif">
          3×8
        </text>
      </g>

      {/* Rest bar */}
      <rect x="30" y="184" width="148" height="10" rx="5" fill={SAGE} opacity="0.6" />
      <text x="100" y="192" fill={STROKE} fontSize="7" fontFamily="sans-serif" textAnchor="middle">
        rest 60s
      </text>

      <g>
        <rect x="30" y="202" width="148" height="36" rx="6" fill="none" stroke={STROKE} strokeWidth="1" />
        <rect x="36" y="208" width="24" height="24" rx="3" fill={STROKE_DIM} opacity="0.4" />
        <text x="68" y="220" fill={STROKE} fontSize="8" fontFamily="sans-serif">
          Plank
        </text>
        <text x="68" y="230" fill={STROKE_DIM} fontSize="7" fontFamily="sans-serif">
          3×30s
        </text>
      </g>

      {/* Cycles label */}
      <text x="100" y="262" fill={CORAL} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        2 cycles
      </text>
    </PhoneFrame>
  );
}

export function StepPreview() {
  return (
    <PhoneFrame caption="Preview — see what your client will see">
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Preview
      </text>

      {/* Card centered */}
      <rect x="32" y="80" width="136" height="170" rx="10" fill="none" stroke={CORAL} strokeWidth="1.5" />

      {/* Stick figure suggestion */}
      <circle cx="100" cy="120" r="10" fill="none" stroke={STROKE} strokeWidth="1.2" />
      <line x1="100" y1="130" x2="100" y2="170" stroke={STROKE} strokeWidth="1.2" />
      <line x1="100" y1="142" x2="84" y2="156" stroke={STROKE} strokeWidth="1.2" />
      <line x1="100" y1="142" x2="116" y2="156" stroke={STROKE} strokeWidth="1.2" />
      <line x1="100" y1="170" x2="86" y2="190" stroke={STROKE} strokeWidth="1.2" />
      <line x1="100" y1="170" x2="114" y2="190" stroke={STROKE} strokeWidth="1.2" />

      <text x="100" y="216" fill={STROKE} fontSize="9" fontFamily="sans-serif" textAnchor="middle">
        Squat
      </text>

      {/* Treatment segmented control */}
      <rect x="46" y="226" width="108" height="14" rx="7" fill="none" stroke={STROKE_DIM} strokeWidth="0.8" />
      <rect x="46" y="226" width="36" height="14" rx="7" fill={CORAL} opacity="0.25" />
      <text x="64" y="236" fill={CORAL} fontSize="7" fontFamily="sans-serif" textAnchor="middle">
        Line
      </text>
      <text x="100" y="236" fill={STROKE_DIM} fontSize="7" fontFamily="sans-serif" textAnchor="middle">
        B&amp;W
      </text>
      <text x="136" y="236" fill={STROKE_DIM} fontSize="7" fontFamily="sans-serif" textAnchor="middle">
        Original
      </text>

      {/* Dot indicators */}
      <g>
        <circle cx="86" cy="278" r="2.5" fill={STROKE_DIM} />
        <circle cx="100" cy="278" r="3" fill={CORAL} />
        <circle cx="114" cy="278" r="2.5" fill={STROKE_DIM} />
      </g>

      {/* Nav chevrons */}
      <polyline points="22,150 16,160 22,170" fill="none" stroke={STROKE_DIM} strokeWidth="1.5" />
      <polyline points="178,150 184,160 178,170" fill="none" stroke={STROKE_DIM} strokeWidth="1.5" />
    </PhoneFrame>
  );
}

export function StepPublish() {
  return (
    <PhoneFrame caption="Publish — runs in the background">
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Studio
      </text>

      {/* Workflow pill — Publish highlighted */}
      <rect x="32" y="68" width="136" height="20" rx="10" fill="none" stroke={STROKE_DIM} strokeWidth="0.8" />
      <text x="58" y="81" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        Capture
      </text>
      <text x="98" y="81" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        Preview
      </text>
      <rect x="120" y="70" width="46" height="16" rx="8" fill={CORAL} />
      <text x="143" y="81" fill="white" fontSize="8" fontFamily="sans-serif" textAnchor="middle" fontWeight="600">
        Publish
      </text>

      {/* Arrow */}
      <line x1="143" y1="100" x2="143" y2="112" stroke={CORAL} strokeWidth="1.5" />
      <polygon points="139,112 147,112 143,118" fill={CORAL} />

      {/* Cards faded behind */}
      <rect x="30" y="140" width="148" height="22" rx="4" fill="none" stroke={STROKE_DIM} strokeWidth="0.6" opacity="0.5" />
      <rect x="30" y="168" width="148" height="22" rx="4" fill="none" stroke={STROKE_DIM} strokeWidth="0.6" opacity="0.5" />
      <rect x="30" y="196" width="148" height="22" rx="4" fill="none" stroke={STROKE_DIM} strokeWidth="0.6" opacity="0.5" />

      {/* Toast */}
      <rect x="40" y="270" width="120" height="28" rx="14" fill={CORAL} />
      <circle cx="58" cy="284" r="6" fill="none" stroke="white" strokeWidth="1.5" />
      <polyline points="55,284 57,287 62,281" fill="none" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
      <text x="100" y="288" fill="white" fontSize="9" fontFamily="sans-serif" textAnchor="middle" fontWeight="600">
        Published
      </text>
    </PhoneFrame>
  );
}

export function StepShare() {
  return (
    <PhoneFrame caption="Share — send the link via WhatsApp">
      <text x="22" y="50" fill={STROKE} fontSize="11" fontFamily="sans-serif">
        Share
      </text>

      {/* Plan URL preview card */}
      <rect x="22" y="68" width="156" height="44" rx="6" fill="none" stroke={STROKE_DIM} strokeWidth="1" />
      <text x="30" y="84" fill={STROKE} fontSize="8" fontFamily="sans-serif">
        Sarah&apos;s plan
      </text>
      <text x="30" y="98" fill={STROKE_DIM} fontSize="7" fontFamily="monospace">
        session.homefit.studio/p/...
      </text>

      {/* Share sheet drawer */}
      <rect x="14" y="140" width="172" height="180" rx="12" fill={STROKE_DIM} opacity="0.15" />
      <rect x="86" y="148" width="28" height="3" rx="1.5" fill={STROKE_DIM} />

      <text x="100" y="172" fill={STROKE} fontSize="9" fontFamily="sans-serif" textAnchor="middle">
        Share via
      </text>

      {/* App row */}
      <g>
        {/* WhatsApp — coral highlight */}
        <circle cx="46" cy="210" r="18" fill={CORAL} />
        <path
          d="M 38 212 q 0 8 8 8 q 8 0 8 -8 q 0 -8 -8 -8 q -8 0 -8 8 z"
          fill="none"
          stroke="white"
          strokeWidth="1.8"
        />
        <line x1="40" y1="218" x2="44" y2="222" stroke="white" strokeWidth="1.8" strokeLinecap="round" />
        <text x="46" y="244" fill={CORAL} fontSize="8" fontFamily="sans-serif" textAnchor="middle" fontWeight="600">
          WhatsApp
        </text>
      </g>
      <g>
        <circle cx="100" cy="210" r="18" fill="none" stroke={STROKE_DIM} strokeWidth="1.2" />
        <text x="100" y="244" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
          Messages
        </text>
      </g>
      <g>
        <circle cx="154" cy="210" r="18" fill="none" stroke={STROKE_DIM} strokeWidth="1.2" />
        <text x="154" y="244" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
          Mail
        </text>
      </g>

      {/* Copy link row */}
      <line x1="22" y1="270" x2="178" y2="270" stroke={STROKE_DIM} strokeWidth="0.5" />
      <text x="100" y="290" fill={STROKE} fontSize="9" fontFamily="sans-serif" textAnchor="middle">
        Copy link
      </text>
    </PhoneFrame>
  );
}

// ---------------------------------------------------------------------------
// Refine sub-section accent illustrations.
// ---------------------------------------------------------------------------

export function RefineRepsSets() {
  return (
    <MiniFrame caption="Reps and sets steppers">
      <text x="10" y="20" fill={STROKE} fontSize="9" fontFamily="sans-serif">
        Reps
      </text>
      <rect x="10" y="26" width="60" height="20" rx="4" fill="none" stroke={STROKE_DIM} strokeWidth="0.8" />
      <text x="20" y="40" fill={STROKE_DIM} fontSize="11" fontFamily="sans-serif" textAnchor="middle">
        −
      </text>
      <text x="40" y="41" fill={CORAL} fontSize="11" fontFamily="sans-serif" textAnchor="middle" fontWeight="600">
        10
      </text>
      <text x="60" y="40" fill={STROKE_DIM} fontSize="11" fontFamily="sans-serif" textAnchor="middle">
        +
      </text>

      <text x="90" y="20" fill={STROKE} fontSize="9" fontFamily="sans-serif">
        Sets
      </text>
      <rect x="90" y="26" width="60" height="20" rx="4" fill="none" stroke={STROKE_DIM} strokeWidth="0.8" />
      <text x="100" y="40" fill={STROKE_DIM} fontSize="11" fontFamily="sans-serif" textAnchor="middle">
        −
      </text>
      <text x="120" y="41" fill={CORAL} fontSize="11" fontFamily="sans-serif" textAnchor="middle" fontWeight="600">
        3
      </text>
      <text x="140" y="40" fill={STROKE_DIM} fontSize="11" fontFamily="sans-serif" textAnchor="middle">
        +
      </text>

      <text x="80" y="76" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        3 sets × 10 reps
      </text>
    </MiniFrame>
  );
}

export function RefineTrim() {
  return (
    <MiniFrame caption="Trim handles — drag inward to clip">
      {/* Filmstrip */}
      <rect x="10" y="30" width="140" height="40" rx="4" fill={STROKE_DIM} opacity="0.2" />
      {/* Frame ticks */}
      {[20, 40, 60, 80, 100, 120, 140].map((x, i) => (
        <line
          key={i}
          x1={x}
          y1="30"
          x2={x}
          y2="70"
          stroke={STROKE_DIM}
          strokeWidth="0.4"
        />
      ))}

      {/* Selected window */}
      <rect x="35" y="30" width="90" height="40" fill={CORAL} opacity="0.12" />

      {/* Coral handles */}
      <rect x="32" y="22" width="6" height="56" rx="2" fill={CORAL} />
      <line x1="35" y1="34" x2="35" y2="66" stroke="white" strokeWidth="0.8" />

      <rect x="122" y="22" width="6" height="56" rx="2" fill={CORAL} />
      <line x1="125" y1="34" x2="125" y2="66" stroke="white" strokeWidth="0.8" />

      <text x="80" y="92" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        in · · · · · · · · · · · out
      </text>
    </MiniFrame>
  );
}

export function RefineHero() {
  return (
    <MiniFrame caption="Hero frame scrubber — pick the still">
      {/* Filmstrip thumbnails */}
      {[10, 38, 66, 94, 122].map((x, i) => {
        const selected = i === 2;
        return (
          <g key={i}>
            <rect
              x={x}
              y="20"
              width="28"
              height="40"
              rx="3"
              fill="none"
              stroke={selected ? CORAL : STROKE_DIM}
              strokeWidth={selected ? '1.5' : '0.8'}
            />
            {/* Stick figure suggestion */}
            <circle cx={x + 14} cy="32" r="3" fill="none" stroke={selected ? CORAL : STROKE_DIM} strokeWidth="0.8" />
            <line x1={x + 14} y1="35" x2={x + 14} y2="48" stroke={selected ? CORAL : STROKE_DIM} strokeWidth="0.8" />
            <line x1={x + 14} y1="40" x2={x + 8} y2="46" stroke={selected ? CORAL : STROKE_DIM} strokeWidth="0.8" />
            <line x1={x + 14} y1="40" x2={x + 20} y2="46" stroke={selected ? CORAL : STROKE_DIM} strokeWidth="0.8" />
          </g>
        );
      })}
      {/* Selected indicator */}
      <polygon points="74,68 82,68 78,74" fill={CORAL} />
      <text x="80" y="90" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        the still your client sees
      </text>
    </MiniFrame>
  );
}

export function RefineCircuit() {
  return (
    <MiniFrame caption="Circuit — bracket consecutive cards">
      {/* Cards */}
      <rect x="40" y="14" width="100" height="16" rx="3" fill="none" stroke={STROKE} strokeWidth="0.8" />
      <text x="48" y="25" fill={STROKE} fontSize="8" fontFamily="sans-serif">
        Squat
      </text>
      <rect x="40" y="34" width="100" height="16" rx="3" fill="none" stroke={STROKE} strokeWidth="0.8" />
      <text x="48" y="45" fill={STROKE} fontSize="8" fontFamily="sans-serif">
        Lunge
      </text>
      <rect x="40" y="54" width="100" height="16" rx="3" fill="none" stroke={STROKE} strokeWidth="0.8" />
      <text x="48" y="65" fill={STROKE} fontSize="8" fontFamily="sans-serif">
        Plank
      </text>

      {/* Coral bracket on left */}
      <line x1="28" y1="14" x2="28" y2="70" stroke={CORAL} strokeWidth="2" strokeLinecap="round" />
      <line x1="28" y1="14" x2="36" y2="14" stroke={CORAL} strokeWidth="2" strokeLinecap="round" />
      <line x1="28" y1="70" x2="36" y2="70" stroke={CORAL} strokeWidth="2" strokeLinecap="round" />

      {/* Cycles label */}
      <text x="20" y="46" fill={CORAL} fontSize="7" fontFamily="sans-serif" textAnchor="middle" transform="rotate(-90 20 46)">
        ×3
      </text>

      <text x="80" y="88" fill={STROKE_DIM} fontSize="8" fontFamily="sans-serif" textAnchor="middle">
        3 cycles, unrolled per round
      </text>
    </MiniFrame>
  );
}
