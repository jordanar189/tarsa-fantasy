// Pure helpers for sync_schedules: ET kickoff reconstruction from the
// nflverse gameday/gametime columns, and the merge rules that keep a blind
// daily upsert from clobbering better data written by the other schedule
// writers (sync_schedules_espn's exact UTC kickoffs, sync_espn_live's
// overnight finals). Deno-testable, no I/O.

export interface ScheduleRow {
    game_id: string; season: number; week: number;
    home_team: string; away_team: string;
    kickoff: string | null;
    home_score: number | null;
    away_score: number | null;
    status: string;
}

export interface ExistingRow {
    game_id: string;
    kickoff: string | null;
    status: string;
    home_score: number | null;
    away_score: number | null;
}

export function mergeExisting(row: ScheduleRow, existing: ExistingRow | undefined) {
    if (!existing) return;
    // Kickoff: an existing timestamp within 2h of the derived one is the same
    // game slot from a more precise source (ESPN's exact UTC vs our
    // gameday+gametime reconstruction) — keep it. A larger gap is a real
    // reschedule (flexed game) that nflverse knows about — take the new time.
    if (existing.kickoff && row.kickoff) {
        const gap = Math.abs(
            new Date(existing.kickoff).getTime() - new Date(row.kickoff).getTime()
        );
        if (Number.isFinite(gap) && gap <= 2 * 3600 * 1000) {
            row.kickoff = existing.kickoff;
        }
    } else if (existing.kickoff) {
        row.kickoff = existing.kickoff;
    }
    // Finals: the CSV lags live results by up to a day. Don't regress a final
    // written by sync_espn_live back to in_progress with nulled scores; a
    // result in the CSV (row.status === 'final') is authoritative and wins.
    if (row.status !== "final" && existing.status === "final"
        && existing.home_score != null && existing.away_score != null) {
        row.status = "final";
        row.home_score = existing.home_score;
        row.away_score = existing.away_score;
    }
}

// gameday is "YYYY-MM-DD", gametime is "HH:MM" Eastern — build an ET timestamp
// with the correct seasonal offset (EDT −04:00 during US daylight saving,
// EST −05:00 otherwise). September/October games are EDT, so a fixed −05:00
// put every early-season kickoff an hour late — enough to matter for lineup
// locks and the trade-lock window.
export function combineKickoff(day: string | undefined, time: string | undefined): string | null {
    if (!day) return null;
    const d = day.trim();
    if (!d || d.toUpperCase() === "NA") return null;
    const t = (time ?? "").trim();
    const hhmm = /^\d{1,2}:\d{2}$/.test(t) ? t.padStart(5, "0") : "13:00";
    return `${d}T${hhmm}:00${easternOffset(d)}`;
}

// US DST: second Sunday of March through first Sunday of November. Day
// granularity is fine — no NFL game kicks off during the 2 AM changeover.
export function easternOffset(day: string): string {
    const [y, m, dd] = day.split("-").map((s) => Number(s));
    if (!y || !m || !dd) return "-05:00";
    const nthSundayOfMonth = (month: number, n: number): number => {
        const firstWeekday = new Date(Date.UTC(y, month - 1, 1)).getUTCDay();
        return 1 + ((7 - firstWeekday) % 7) + (n - 1) * 7;
    };
    const key = m * 100 + dd;
    const dstStart = 3 * 100 + nthSundayOfMonth(3, 2);
    const dstEnd = 11 * 100 + nthSundayOfMonth(11, 1);
    return key >= dstStart && key < dstEnd ? "-04:00" : "-05:00";
}
