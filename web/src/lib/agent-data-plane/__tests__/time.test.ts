import { describe, expect, it } from "vitest";
import {
  addCalendarDays,
  isoWeekStart,
  localDate,
  zonedLocalDateTimeToUtc,
} from "../time";
import { nextScheduleOccurrence } from "../automations";

describe("timezone reducers", () => {
  it("assigns the same instant to each user's local date", () => {
    const instant = new Date("2026-08-28T16:30:00.000Z");
    expect(localDate(instant, "Asia/Shanghai")).toBe("2026-08-29");
    expect(localDate(instant, "America/Los_Angeles")).toBe("2026-08-28");
  });

  it("converts local wall time to UTC across offsets", () => {
    expect(zonedLocalDateTimeToUtc("2026-08-29", "04:00", "Asia/Shanghai").toISOString()).toBe(
      "2026-08-28T20:00:00.000Z",
    );
    expect(zonedLocalDateTimeToUtc("2026-01-12", "09:00", "America/New_York").toISOString()).toBe(
      "2026-01-12T14:00:00.000Z",
    );
  });

  it("finds the next semantic weekly schedule without raw cron", () => {
    const next = nextScheduleOccurrence(
      { type: "schedule", local_time: "09:00", weekdays: ["monday"] },
      "Asia/Shanghai",
      new Date("2026-08-28T00:00:00.000Z"),
    );
    expect(next.toISOString()).toBe("2026-08-31T01:00:00.000Z");
  });

  it("uses ISO Monday and calendar-day arithmetic", () => {
    expect(isoWeekStart("2026-08-30")).toBe("2026-08-24");
    expect(addCalendarDays("2026-02-28", 1)).toBe("2026-03-01");
  });
});
