import { memberTone } from "./ui";

type Seat = {
  name: string;
  you: boolean;
  status: string;
  lost: string;
  debt: string;
};

const C = 180;
const TRACK = 118;
const rad = (deg: number) => ((deg - 90) * Math.PI) / 180;
const at = (deg: number, r: number) => [
  C + r * Math.cos(rad(deg)),
  C + r * Math.sin(rad(deg)),
];

function arc(from: number, to: number, r: number) {
  const [x1, y1] = at(from, r);
  const [x2, y2] = at(to, r);
  return `M ${x1} ${y1} A ${r} ${r} 0 ${to - from > 180 ? 1 : 0} 1 ${x2} ${y2}`;
}

const short = (name: string) =>
  name.length > 9 ? `${name.slice(0, 8)}…` : name;

/** The circle itself: members seated around the round track, the pot in the middle. */
export function Ring({
  seats,
  round,
  totalRounds,
  status,
  centerTop,
  centerMain,
  centerBottom,
}: {
  seats: Seat[];
  round: number;
  totalRounds: number;
  status: string;
  centerTop: string;
  centerMain: string;
  centerBottom: string;
}) {
  const done = status === "Completed" ? totalRounds : Math.max(0, round - 1);
  const gap = 6;
  const span = 360 / Math.max(totalRounds, 1);
  const step = 360 / Math.max(seats.length, 1);
  return (
    <svg
      viewBox="0 0 360 360"
      className="block h-auto w-full max-w-[290px] sm:max-w-[340px]"
      aria-hidden
    >
      {Array.from({ length: totalRounds }, (_, i) => {
        const tone =
          i < done
            ? "var(--color-brand)"
            : i === done && status === "Active"
              ? "var(--color-accent)"
              : "var(--color-line)";
        return (
          <path
            // biome-ignore lint/suspicious/noArrayIndexKey: rounds are positional
            key={i}
            d={arc(i * span + gap / 2, (i + 1) * span - gap / 2, TRACK)}
            fill="none"
            stroke={tone}
            strokeWidth={10}
            strokeLinecap="round"
          />
        );
      })}
      <text
        x={C}
        y={C - 30}
        textAnchor="middle"
        fontSize="15"
        fill="var(--color-ink-2)"
      >
        {centerTop}
      </text>
      <text
        x={C}
        y={C + 8}
        textAnchor="middle"
        fontSize="36"
        fontWeight="700"
        fill="var(--color-ink)"
        style={{
          fontFamily: "var(--font-display)",
          fontVariantNumeric: "tabular-nums",
        }}
      >
        {centerMain}
      </text>
      <text
        x={C}
        y={C + 34}
        textAnchor="middle"
        fontSize="15"
        fill="var(--color-ink-2)"
      >
        {centerBottom}
      </text>
      {seats.map((s, i) => {
        const deg = i * step;
        const [x, y] = at(deg, TRACK);
        const [lx, ly] = at(deg, TRACK + 44);
        const tone = memberTone(s.status, s.lost, s.debt);
        const empty = /not joined/i.test(s.status);
        const stroke = s.you
          ? "var(--color-ink)"
          : tone === "bad"
            ? "var(--color-bad)"
            : tone === "warn"
              ? "var(--color-warn)"
              : "var(--color-brand)";
        const fill = empty
          ? "var(--color-paper)"
          : s.you
            ? "var(--color-accent)"
            : tone === "bad"
              ? "var(--color-bad-soft)"
              : tone === "warn"
                ? "var(--color-warn-soft)"
                : "var(--color-surface)";
        return (
          <g key={s.name}>
            <circle
              cx={x}
              cy={y}
              r={24}
              fill={fill}
              stroke={stroke}
              strokeWidth={tone === "bad" && !s.you ? 3.5 : 2.5}
              strokeDasharray={empty || tone === "warn" ? "5 4" : undefined}
            />
            <text
              x={x}
              y={y + 7}
              textAnchor="middle"
              fontSize="20"
              fontWeight="700"
              fill={
                tone === "bad" && !s.you
                  ? "var(--color-bad)"
                  : "var(--color-ink)"
              }
              style={{ fontFamily: "var(--font-display)" }}
            >
              {empty ? "+" : s.name.slice(0, 1).toUpperCase()}
            </text>
            <text
              x={lx}
              y={ly + 5}
              textAnchor="middle"
              fontSize="15"
              fontWeight={s.you ? 700 : 500}
              fill="var(--color-ink)"
            >
              {s.you ? "You" : short(s.name)}
            </text>
          </g>
        );
      })}
    </svg>
  );
}
